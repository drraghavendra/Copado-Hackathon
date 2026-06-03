// cipgDashboard.js
// ─────────────────────────────────────────────────────────────────────────────
// LWC controller for the CIPG main dashboard.
// Uses @wire for reactive Apex data + manual refresh via imperative calls.
// Subscribes to Platform Events for real-time incident updates.

import { LightningElement, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { subscribe, unsubscribe, onError } from 'lightning/empApi';

// Apex imports
import getActiveIncidents   from '@salesforce/apex/CIPGDashboardController.getActiveIncidents';
import getStats             from '@salesforce/apex/CIPGDashboardController.getStats';
import getKBEntries         from '@salesforce/apex/CIPGDashboardController.getKBEntries';
import applyOverride        from '@salesforce/apex/CIPGDashboardController.applyManualOverride';

// Platform event channel for live updates
const INCIDENT_CHANNEL = '/event/CIPG_Incident_Event__e';

export default class CipgDashboard extends LightningElement {

    // ── Tracked state ─────────────────────────────────────────────────────────
    @track incidents        = [];
    @track filteredIncidents = [];
    @track kbEntries        = [];
    @track stats            = {};
    @track selectedIncident = null;
    @track isLoading        = true;
    @track errorMessage     = null;
    @track activeTab        = 'incidents';
    @track showOverrideModal = false;
    @track overrideNotes    = '';
    @track overrideStatus   = 'Resolved';
    @track overrideIncidentId = null;

    // Filters
    @track searchTerm     = '';
    @track selectedType   = '';
    @track selectedStatus = '';

    // Platform Events subscription handle
    _subscription = {};

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    connectedCallback() {
        this.loadData();
        this.subscribeToEvents();
        // Auto-refresh every 60 seconds
        this._refreshInterval = setInterval(() => this.loadData(), 60000);
    }

    disconnectedCallback() {
        clearInterval(this._refreshInterval);
        this.unsubscribeFromEvents();
    }

    // ── Data loading ──────────────────────────────────────────────────────────
    async loadData() {
        this.isLoading = true;
        try {
            const [incidents, stats, kbEntries] = await Promise.all([
                getActiveIncidents(),
                getStats(),
                getKBEntries({ limitCount: 50 })
            ]);

            this.incidents = incidents.map(inc => ({
                ...inc,
                severityClass : this.getSeverityClass(inc.Failure_Type__c),
                typeLabel     : this.formatType(inc.Failure_Type__c),
                isActive      : this.selectedIncident?.Id === inc.Id,
                relativeTime  : this.getRelativeTime(inc.Failed_At__c)
            }));

            this.stats    = stats;
            this.kbEntries = kbEntries;
            this.applyFilters();
            this.errorMessage = null;
        } catch (error) {
            this.errorMessage = 'Failed to load dashboard data: ' + error.body?.message;
        } finally {
            this.isLoading = false;
        }
    }

    // ── Platform Event subscription ───────────────────────────────────────────
    subscribeToEvents() {
        const messageCallback = (response) => {
            const data = response.data.payload;
            this.handleLiveEvent(data);
        };

        subscribe(INCIDENT_CHANNEL, -1, messageCallback)
            .then(subscription => {
                this._subscription = subscription;
            });

        onError(error => {
            console.error('EMP API error:', error);
        });
    }

    unsubscribeFromEvents() {
        unsubscribe(this._subscription);
    }

    handleLiveEvent(eventData) {
        if (eventData.Event_Type__c === 'NEW_INCIDENT') {
            this.dispatchToast(
                '🚨 New Pipeline Failure',
                eventData.Pipeline_Name__c + ' — ' + this.formatType(eventData.Failure_Type__c),
                'error'
            );
            this.loadData();
        } else if (eventData.Event_Type__c === 'INCIDENT_RESOLVED') {
            this.dispatchToast(
                '✅ Incident Resolved',
                eventData.Pipeline_Name__c + ' incident has been resolved.',
                'success'
            );
            this.loadData();
        }
    }

    // ── Event handlers ─────────────────────────────────────────────────────────
    handleIncidentSelect(event) {
        const incidentId = event.detail.incidentId;
        this.selectedIncident = this.incidents.find(i => i.Id === incidentId) || null;

        // Mark active state
        this.incidents = this.incidents.map(inc => ({
            ...inc,
            isActive: inc.Id === incidentId
        }));
        this.applyFilters();
    }

    handleSearch(event) {
        this.searchTerm = event.target.value;
        this.applyFilters();
    }

    handleTypeFilter(event) {
        this.selectedType = event.detail.value;
        this.applyFilters();
    }

    handleStatusFilter(event) {
        this.selectedStatus = event.detail.value;
        this.applyFilters();
    }

    handleTabChange(event) {
        this.activeTab = event.target.value;
    }

    handleMessageSent(event) {
        // Chat message sent from cipgChatPanel — refresh conversation
        const { incidentId } = event.detail;
        // Update the incident's last activity timestamp locally
        this.incidents = this.incidents.map(inc =>
            inc.Id === incidentId
                ? { ...inc, LastModifiedDate: new Date().toISOString() }
                : inc
        );
    }

    handleAgentAction(event) {
        const { action, incidentId } = event.detail;
        this.dispatchToast(
            'Guardian Action',
            'Action "' + action + '" initiated for incident ' + incidentId,
            'info'
        );
        // Reload after a short delay to pick up status changes
        setTimeout(() => this.loadData(), 3000);
    }

    handleManualOverride(event) {
        this.overrideIncidentId = event.detail.incidentId;
        this.showOverrideModal  = true;
    }

    async applyManualOverride() {
        try {
            await applyOverride({
                incidentId : this.overrideIncidentId,
                notes      : this.overrideNotes,
                newStatus  : this.overrideStatus
            });
            this.dispatchToast('Override Applied', 'Incident status updated.', 'success');
            this.closeOverrideModal();
            await this.loadData();
        } catch (error) {
            this.dispatchToast('Override Failed', error.body?.message, 'error');
        }
    }

    closeOverrideModal() {
        this.showOverrideModal  = false;
        this.overrideNotes      = '';
        this.overrideIncidentId = null;
    }

    openNewIncidentModal() {
        // Navigate to new incident record form
        this[NavigationMixin.Navigate]({
            type  : 'standard__objectPage',
            attributes: {
                objectApiName : 'Copado_Incident__c',
                actionName    : 'new'
            }
        });
    }

    handleOverrideNotesChange(event)  { this.overrideNotes  = event.detail.value; }
    handleOverrideStatusChange(event) { this.overrideStatus = event.detail.value; }
    clearError() { this.errorMessage = null; }
    refreshData() { this.loadData(); }

    handleKbRowAction(event) {
        const row = event.detail.row;
        this.dispatchToast(
            'KB Entry: ' + row.Name,
            'Pattern: ' + row.Error_Pattern__c,
            'info'
        );
    }

    // ── Filter logic ──────────────────────────────────────────────────────────
    applyFilters() {
        let result = [...this.incidents];

        if (this.searchTerm) {
            const term = this.searchTerm.toLowerCase();
            result = result.filter(i =>
                (i.Pipeline_Name__c || '').toLowerCase().includes(term) ||
                (i.Error_Message__c || '').toLowerCase().includes(term) ||
                (i.Branch_Name__c   || '').toLowerCase().includes(term)
            );
        }

        if (this.selectedType) {
            result = result.filter(i => i.Failure_Type__c === this.selectedType);
        }

        if (this.selectedStatus) {
            result = result.filter(i => i.Status__c === this.selectedStatus);
        }

        this.filteredIncidents = result;
    }

    // ── Computed getters ──────────────────────────────────────────────────────
    get activeIncidentCount() {
        return this.incidents.filter(i =>
            ['New', 'In Triage', 'Retrying'].includes(i.Status__c)
        ).length;
    }

    get failureTypeOptions() {
        return [
            { label: 'All Types',           value: '' },
            { label: 'Apex Test Failure',   value: 'APEX_TEST' },
            { label: 'Merge Conflict',       value: 'MERGE_CONFLICT' },
            { label: 'Deployment Timeout',   value: 'DEPLOYMENT_TIMEOUT' },
            { label: 'Static Analysis',      value: 'STATIC_ANALYSIS' }
        ];
    }

    get statusOptions() {
        return [
            { label: 'All Statuses',  value: '' },
            { label: 'New',           value: 'New' },
            { label: 'In Triage',     value: 'In Triage' },
            { label: 'Retrying',      value: 'Retrying' },
            { label: 'Auto-Resolved', value: 'Auto-Resolved' },
            { label: 'Resolved',      value: 'Resolved' },
            { label: 'Dismissed',     value: 'Dismissed' }
        ];
    }

    get overrideStatusOptions() {
        return [
            { label: 'Resolved',   value: 'Resolved' },
            { label: 'Dismissed',  value: 'Dismissed' },
            { label: 'Escalated',  value: 'Escalated' },
            { label: 'In Triage',  value: 'In Triage' }
        ];
    }

    get kbColumns() {
        return [
            { label: 'Name',         fieldName: 'Name',               type: 'text' },
            { label: 'Type',         fieldName: 'Failure_Type__c',     type: 'text' },
            { label: 'Pattern',      fieldName: 'Error_Pattern__c',    type: 'text', wrapText: true },
            { label: 'Resolution',   fieldName: 'Resolution__c',       type: 'text', wrapText: true },
            { label: 'Occurrences',  fieldName: 'Occurrence_Count__c', type: 'number' },
            { label: 'Confidence',   fieldName: 'Confidence_Score__c', type: 'percent',
              typeAttributes: { maximumFractionDigits: 0 } },
            { label: 'Last Seen',    fieldName: 'Last_Seen__c',        type: 'date-local' },
            { type: 'action', typeAttributes: {
                rowActions: [{ label: 'View Details', name: 'view' }]
            }}
        ];
    }

    // ── Helpers ───────────────────────────────────────────────────────────────
    getSeverityClass(failureType) {
        const map = {
            'APEX_TEST'          : 'slds-theme_error',
            'MERGE_CONFLICT'     : 'slds-theme_warning',
            'DEPLOYMENT_TIMEOUT' : 'slds-theme_info',
            'STATIC_ANALYSIS'   : 'slds-theme_shade'
        };
        return map[failureType] || 'slds-theme_shade';
    }

    formatType(type) {
        const map = {
            'APEX_TEST'          : 'Apex Test Failure',
            'MERGE_CONFLICT'     : 'Merge Conflict',
            'DEPLOYMENT_TIMEOUT' : 'Deployment Timeout',
            'STATIC_ANALYSIS'   : 'Static Analysis'
        };
        return map[type] || type;
    }

    getRelativeTime(isoString) {
        if (!isoString) return '';
        const diff = Date.now() - new Date(isoString).getTime();
        const minutes = Math.floor(diff / 60000);
        if (minutes < 1)   return 'Just now';
        if (minutes < 60)  return minutes + 'm ago';
        const hours = Math.floor(minutes / 60);
        if (hours < 24)    return hours + 'h ago';
        return Math.floor(hours / 24) + 'd ago';
    }

    dispatchToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
