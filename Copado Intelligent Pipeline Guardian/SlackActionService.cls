/**
 * SlackActionService
 * ─────────────────────────────────────────────────────────────────────────────
 * Handles developer button-click actions received from Slack interactive
 * components. Each action may trigger Copado API calls, Jira ticket creation,
 * or additional AI conversation steps.
 */
public with sharing class SlackActionService {

    @future(callout=true)
    public static void handleActionAsync(
        String incidentId, String action,
        String channel, String threadTs, String userId
    ) {
        new SlackActionService().handleAction(
            incidentId, action, channel, threadTs, userId
        );
    }

    public void handleAction(
        String incidentId, String action,
        String channel, String threadTs, String userId
    ) {
        Copado_Incident__c incident = fetchIncident(incidentId);
        if (incident == null) return;

        switch on action {
            when 'pull_logs' {
                handlePullLogs(incident, channel, threadTs);
            }
            when 'rerun_tests' {
                handleRerunTests(incident, channel, threadTs);
            }
            when 'create_jira' {
                handleCreateJira(incident, channel, threadTs);
            }
            when 'dismiss' {
                handleDismiss(incident, channel, threadTs, userId);
            }
            when 'view_kb' {
                handleViewKB(incident, channel, threadTs);
            }
            when else {
                SlackMessagingService.sendThreadReply(
                    channel, threadTs,
                    '⚠️ Unknown action: `' + action + '`', null
                );
            }
        }
    }

    // ── Action Handlers ───────────────────────────────────────────────────────
    private void handlePullLogs(
        Copado_Incident__c inc, String channel, String ts
    ) {
        SlackMessagingService.sendThreadReply(
            channel, ts, '⏳ Fetching Apex debug logs via Copado AI API...', null
        );

        String logs = CopadoAIService.fetchLogs(inc.Pipeline_Id__c);
        String truncated = logs.length() > 2500
            ? logs.substring(0, 2500) + '\n...[truncated]' : logs;

        SlackMessagingService.sendThreadReply(
            channel, ts,
            '📋 *Apex Debug Log*\n```' + truncated + '```',
            new List<Map<String, String>>{
                new Map<String, String>{
                    'id' => 'rerun_tests', 'label' => '🔄 Re-run Tests',
                    'style' => 'primary',
                    'value' => inc.Id + '|rerun_tests'
                },
                new Map<String, String>{
                    'id' => 'create_jira', 'label' => '🐛 Create Jira',
                    'style' => 'default',
                    'value' => inc.Id + '|create_jira'
                }
            }
        );

        // Store log in incident record
        inc.Full_Log__c = logs;
        update inc;
    }

    private void handleRerunTests(
        Copado_Incident__c inc, String channel, String ts
    ) {
        List<String> failedClasses = String.isBlank(inc.Failed_Test_Classes__c)
            ? new List<String>() : inc.Failed_Test_Classes__c.split(',');

        CopadoAIService.rerunTests(inc.Pipeline_Id__c, failedClasses);

        inc.Status__c = 'Retrying';
        update inc;

        SlackMessagingService.sendThreadReply(
            channel, ts,
            '✅ *Test Re-run Queued*\n' +
            'Rerunning ' + failedClasses.size() + ' failed test class(es) via Copado.\n' +
            'I\'ll notify you here when results are ready. Estimated: ~3 minutes.',
            null
        );
    }

    private void handleCreateJira(
        Copado_Incident__c inc, String channel, String ts
    ) {
        JiraIntegrationService.JiraTicket ticket =
            JiraIntegrationService.createTicket(inc);

        inc.Jira_Ticket_Key__c = ticket.key;
        inc.Jira_Ticket_URL__c = ticket.url;
        update inc;

        SlackMessagingService.sendThreadReply(
            channel, ts,
            '📋 *Jira Ticket Created*\n' +
            '*Key:* `' + ticket.key + '`\n' +
            '*Title:* ' + ticket.summary + '\n' +
            '*Priority:* High\n' +
            '*Labels:* ' + String.join(ticket.labels, ', ') + '\n' +
            '<' + ticket.url + '|Open in Jira>',
            null
        );
    }

    private void handleDismiss(
        Copado_Incident__c inc, String channel, String ts, String userId
    ) {
        inc.Status__c = 'Dismissed';
        inc.Dismissed_By_Slack_Id__c = userId;
        update inc;

        KnowledgeBaseService.recordResolution(inc.Id, 'Dismissed by developer', false);

        SlackMessagingService.sendThreadReply(
            channel, ts,
            '✕ Incident dismissed by <@' + userId + '>. ' +
            'This interaction has been logged to the knowledge base.',
            null
        );
    }

    private void handleViewKB(
        Copado_Incident__c inc, String channel, String ts
    ) {
        List<CIPG_KB_Entry__c> entries = KnowledgeBaseService.findSimilar(
            inc.Failure_Type__c, inc.Error_Message__c
        );

        if (entries.isEmpty()) {
            SlackMessagingService.sendThreadReply(
                channel, ts,
                '📚 No similar incidents found in the knowledge base. ' +
                'This will be recorded as a new pattern after resolution.',
                null
            );
            return;
        }

        String kbText = '📚 *Knowledge Base Matches*\n\n';
        for (CIPG_KB_Entry__c kb : entries) {
            kbText += '• *' + kb.Name + '*\n'
                + '  Pattern: `' + kb.Error_Pattern__c + '`\n'
                + '  Resolution: ' + kb.Resolution__c + '\n'
                + '  Seen ' + kb.Occurrence_Count__c.intValue() + ' times\n\n';
        }

        SlackMessagingService.sendThreadReply(channel, ts, kbText, null);
    }

    // ── Helper ─────────────────────────────────────────────────────────────────
    private Copado_Incident__c fetchIncident(String incidentId) {
        List<Copado_Incident__c> results = [
            SELECT Id, Pipeline_Id__c, Pipeline_Name__c, Failure_Type__c,
                   Error_Message__c, Branch_Name__c, Developer_Email__c,
                   Slack_User_Id__c, Status__c, Failed_Test_Classes__c,
                   Full_Log__c, RCA_Summary__c, Jira_Ticket_Key__c,
                   Jira_Ticket_URL__c, Dismissed_By_Slack_Id__c
            FROM Copado_Incident__c
            WHERE Id = :incidentId
            LIMIT 1
        ];
        return results.isEmpty() ? null : results[0];
    }
}
