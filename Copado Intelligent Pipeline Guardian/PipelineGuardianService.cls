/**
 * PipelineGuardianService
 * ─────────────────────────────────────────────────────────────────────────────
 * Core orchestration service for the Copado Intelligent Pipeline Guardian.
 * Receives pipeline failure events, calls the Copado AI Platform API for RCA,
 * and initiates conversational triage via Slack / Teams.
 *
 * Architecture:
 *   Copado Webhook ──► WebhookController ──► PipelineGuardianService
 *                                                   │
 *                      ┌──────────────────────────────┤
 *                      ▼                            ▼
 *              CopadoAIService              SlackMessagingService
 *                      │                            │
 *                      ▼                            ▼
 *              KnowledgeBaseService         JiraIntegrationService
 */
public with sharing class PipelineGuardianService {

    // ── Custom exception ────────────────────────────────────────────────────
    public class GuardianException extends Exception {}

    // ── Inner DTOs ───────────────────────────────────────────────────────────
    public class PipelineFailureEvent {
        public String pipelineId       { get; set; }
        public String pipelineName     { get; set; }
        public String failureType      { get; set; } // APEX_TEST | MERGE_CONFLICT | DEPLOYMENT_TIMEOUT | STATIC_ANALYSIS
        public String errorMessage     { get; set; }
        public String logUrl           { get; set; }
        public String branchName       { get; set; }
        public String developerEmail   { get; set; }
        public String developerSlackId { get; set; }
        public String orgId            { get; set; }
        public DateTime failedAt       { get; set; }
        public Map<String, Object> metadata { get; set; }
    }

    public class TriageResult {
        public String incidentId       { get; set; }
        public String rcaSummary       { get; set; }
        public List<String> suggestedActions { get; set; }
        public String slackMessageTs  { get; set; }
        public String kbMatchId       { get; set; }
        public Boolean autoResolved   { get; set; }
        public TriageResult() {
            suggestedActions = new List<String>();
            autoResolved = false;
        }
    }

    // ── Public entry point ───────────────────────────────────────────────────
    /**
     * Called by Record-Triggered Flow or WebhookController.
     * Runs async to avoid governor limit issues in trigger context.
     */
    @future(callout=true)
    public static void handleFailureAsync(String eventJson) {
        PipelineFailureEvent evt = (PipelineFailureEvent)
            JSON.deserialize(eventJson, PipelineFailureEvent.class);
        new PipelineGuardianService().handleFailure(evt);
    }

    /**
     * Synchronous entry point for direct Apex calls.
     */
    public TriageResult handleFailure(PipelineFailureEvent evt) {
        TriageResult result = new TriageResult();
        try {
            // 1. Persist incident record
            Copado_Incident__c incident = createIncidentRecord(evt);
            result.incidentId = incident.Id;

            // 2. Search KB for similar past incidents
            List<CIPG_KB_Entry__c> kbMatches = KnowledgeBaseService.findSimilar(
                evt.failureType, evt.errorMessage
            );

            // 3. Call Copado AI Platform API for root-cause analysis
            CopadoAIService.RCAResponse rca = CopadoAIService.analyzeFailure(
                evt, kbMatches
            );
            result.rcaSummary = rca.summary;
            result.suggestedActions = rca.actions;

            // 4. Update incident with AI findings
            incident.RCA_Summary__c    = rca.summary;
            incident.Confidence_Score__c = rca.confidenceScore;
            incident.Status__c         = 'In Triage';
            update incident;

            // 5. Send conversational triage to Slack / Teams
            SlackMessagingService.TriageMessage msg = buildTriageMessage(
                evt, incident, rca, kbMatches
            );
            String ts = SlackMessagingService.sendTriageMessage(msg);
            result.slackMessageTs = ts;
            incident.Slack_Thread_Ts__c = ts;

            // 6. Auto-resolve if confidence is high enough
            if (rca.confidenceScore >= 0.92 && rca.autoRemediationAvailable) {
                result = attemptAutoRemediation(evt, incident, rca, result);
            }

            // 7. Log to KB if this is a novel pattern
            if (kbMatches.isEmpty()) {
                KnowledgeBaseService.createEntry(evt, rca, incident.Id);
            }

            update incident;
        } catch (Exception ex) {
            logError(ex, evt);
            throw new GuardianException('CIPG triage failed: ' + ex.getMessage(), ex);
        }
        return result;
    }

    // ── Private helpers ──────────────────────────────────────────────────────
    private Copado_Incident__c createIncidentRecord(PipelineFailureEvent evt) {
        Copado_Incident__c inc = new Copado_Incident__c(
            Pipeline_Id__c      = evt.pipelineId,
            Pipeline_Name__c    = evt.pipelineName,
            Failure_Type__c     = evt.failureType,
            Error_Message__c    = evt.errorMessage,
            Branch_Name__c      = evt.branchName,
            Developer_Email__c  = evt.developerEmail,
            Slack_User_Id__c    = evt.developerSlackId,
            Org_Id__c           = evt.orgId,
            Failed_At__c        = evt.failedAt,
            Status__c           = 'New',
            Log_URL__c          = evt.logUrl
        );
        insert inc;
        return inc;
    }

    private SlackMessagingService.TriageMessage buildTriageMessage(
        PipelineFailureEvent evt,
        Copado_Incident__c   incident,
        CopadoAIService.RCAResponse rca,
        List<CIPG_KB_Entry__c> kbMatches
    ) {
        SlackMessagingService.TriageMessage msg = new SlackMessagingService.TriageMessage();
        msg.channel       = evt.developerSlackId;
        msg.incidentId    = incident.Id;
        msg.pipelineName  = evt.pipelineName;
        msg.failureType   = evt.failureType;
        msg.rcaSummary    = rca.summary;
        msg.suggestedFix  = rca.primaryFix;
        msg.confidenceScore = rca.confidenceScore;
        msg.kbMatches     = kbMatches;
        msg.logUrl        = evt.logUrl;
        return msg;
    }

    private TriageResult attemptAutoRemediation(
        PipelineFailureEvent evt,
        Copado_Incident__c   incident,
        CopadoAIService.RCAResponse rca,
        TriageResult result
    ) {
        try {
            if (evt.failureType == 'DEPLOYMENT_TIMEOUT') {
                CopadoAIService.scheduleRetry(evt.pipelineId);
                incident.Status__c = 'Auto-Resolved';
                incident.Resolution_Notes__c = 'Auto-retry scheduled by CIPG.';
                result.autoResolved = true;
            } else if (evt.failureType == 'APEX_TEST' && rca.rerunSafe) {
                CopadoAIService.rerunTests(evt.pipelineId, rca.failedTestClasses);
                incident.Status__c = 'Auto-Remediated';
                result.autoResolved = true;
            }
            KnowledgeBaseService.recordResolution(
                incident.Id, rca.primaryFix, true
            );
        } catch (Exception ex) {
            logError(ex, evt);
        }
        return result;
    }

    private void logError(Exception ex, PipelineFailureEvent evt) {
        CIPG_Error_Log__c log = new CIPG_Error_Log__c(
            Error_Message__c  = ex.getMessage(),
            Stack_Trace__c    = ex.getStackTraceString(),
            Pipeline_Id__c    = evt?.pipelineId,
            Failure_Type__c   = evt?.failureType
        );
        Database.insert(log, false);
    }
}
