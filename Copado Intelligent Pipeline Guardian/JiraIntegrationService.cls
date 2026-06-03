/**
 * JiraIntegrationService
 * ─────────────────────────────────────────────────────────────────────────────
 * Creates Jira issues automatically when a CIPG incident is flagged as a
 * genuine bug. Attaches full RCA context, log snippets, and affected classes.
 *
 * Named Credential: CIPG_Jira  (Basic Auth: email:api_token)
 * Custom Metadata : CIPG_Config__mdt (Jira_Project_Key__c, Jira_Base_URL__c)
 */
public with sharing class JiraIntegrationService {

    // ── Response DTO ──────────────────────────────────────────────────────────
    public class JiraTicket {
        public String key     { get; set; }
        public String id      { get; set; }
        public String url     { get; set; }
        public String summary { get; set; }
        public List<String> labels { get; set; }
        public JiraTicket() { labels = new List<String>(); }
    }

    // ── Create a Jira issue from a CIPG incident ──────────────────────────────
    public static JiraTicket createTicket(Copado_Incident__c inc) {
        CIPG_Config__mdt cfg = getConfig();
        String projectKey = cfg.Jira_Project_Key__c;
        String baseUrl    = cfg.Jira_Base_URL__c;

        List<String> labels = buildLabels(inc);
        String description  = buildJiraDescription(inc);

        Map<String, Object> issueFields = new Map<String, Object>{
            'project'     => new Map<String, String>{ 'key' => projectKey },
            'summary'     => buildSummary(inc),
            'description' => new Map<String, Object>{
                'type'    => 'doc',
                'version' => 1,
                'content' => buildAtlassianDoc(description)
            },
            'issuetype'   => new Map<String, String>{ 'name' => 'Bug' },
            'priority'    => new Map<String, String>{
                'name' => mapPriority(inc.Failure_Type__c)
            },
            'labels'      => labels,
            'customfield_10016' => null // story points — null for bugs
        };

        Map<String, Object> payload = new Map<String, Object>{
            'fields' => issueFields
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:CIPG_Jira/rest/api/3/issue');
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setBody(JSON.serialize(payload));
        req.setTimeout(15000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 201) {
            throw new PipelineGuardianService.GuardianException(
                'Jira create failed: ' + res.getStatusCode() + ' ' + res.getBody()
            );
        }

        Map<String, Object> body = (Map<String, Object>)
            JSON.deserializeUntyped(res.getBody());

        JiraTicket ticket = new JiraTicket();
        ticket.key     = (String) body.get('key');
        ticket.id      = (String) body.get('id');
        ticket.url     = baseUrl + '/browse/' + ticket.key;
        ticket.summary = buildSummary(inc);
        ticket.labels  = labels;
        return ticket;
    }

    // ── Builders ──────────────────────────────────────────────────────────────
    private static String buildSummary(Copado_Incident__c inc) {
        String prefix = formatType(inc.Failure_Type__c);
        String name   = inc.Pipeline_Name__c != null ? inc.Pipeline_Name__c : 'Unknown Pipeline';
        String msg    = inc.Error_Message__c != null
            ? inc.Error_Message__c.left(60) : '';
        return '[CIPG] ' + prefix + ' — ' + name + ': ' + msg;
    }

    private static String buildJiraDescription(Copado_Incident__c inc) {
        return '== CIPG Auto-Generated Ticket ==\n\n'
             + '**Incident ID:** ' + inc.Id + '\n'
             + '**Pipeline:** ' + inc.Pipeline_Name__c + '\n'
             + '**Branch:** ' + inc.Branch_Name__c + '\n'
             + '**Failure Type:** ' + formatType(inc.Failure_Type__c) + '\n'
             + '**Detected At:** ' + inc.Failed_At__c?.format() + '\n\n'
             + '== Root Cause Analysis ==\n\n'
             + (inc.RCA_Summary__c != null ? inc.RCA_Summary__c : 'N/A') + '\n\n'
             + '== Error Message ==\n\n'
             + (inc.Error_Message__c != null ? inc.Error_Message__c : 'N/A') + '\n\n'
             + '== Steps to Reproduce ==\n\n'
             + '1. Trigger the ' + inc.Pipeline_Name__c + ' pipeline\n'
             + '2. Observe failure at the ' + formatType(inc.Failure_Type__c) + ' stage\n\n'
             + '== Log URL ==\n\n' + (inc.Log_URL__c != null ? inc.Log_URL__c : 'N/A');
    }

    private static List<Object> buildAtlassianDoc(String text) {
        // Atlassian Document Format (ADF) for Jira Cloud
        List<Object> paragraphs = new List<Object>();
        for (String line : text.split('\n')) {
            paragraphs.add(new Map<String, Object>{
                'type'    => 'paragraph',
                'content' => new List<Object>{
                    new Map<String, Object>{ 'type' => 'text', 'text' => line }
                }
            });
        }
        return paragraphs;
    }

    private static List<String> buildLabels(Copado_Incident__c inc) {
        List<String> labels = new List<String>{ 'cipg-auto', 'pipeline-failure' };
        if (inc.Failure_Type__c == 'APEX_TEST')          labels.add('apex-test');
        if (inc.Failure_Type__c == 'MERGE_CONFLICT')      labels.add('merge-conflict');
        if (inc.Failure_Type__c == 'DEPLOYMENT_TIMEOUT')  labels.add('deployment');
        if (inc.Failure_Type__c == 'STATIC_ANALYSIS')     labels.add('code-quality');
        if (inc.Pipeline_Name__c != null) {
            labels.add(inc.Pipeline_Name__c.toLowerCase().replace(' ', '-'));
        }
        return labels;
    }

    private static String mapPriority(String failureType) {
        Map<String, String> priorities = new Map<String, String>{
            'APEX_TEST'          => 'High',
            'MERGE_CONFLICT'     => 'Medium',
            'DEPLOYMENT_TIMEOUT' => 'Medium',
            'STATIC_ANALYSIS'   => 'Low'
        };
        return priorities.containsKey(failureType) ? priorities.get(failureType) : 'Medium';
    }

    private static String formatType(String t) {
        Map<String, String> labels = new Map<String, String>{
            'APEX_TEST'          => 'Apex Test Failure',
            'MERGE_CONFLICT'     => 'Merge Conflict',
            'DEPLOYMENT_TIMEOUT' => 'Deployment Timeout',
            'STATIC_ANALYSIS'   => 'Static Analysis Failure'
        };
        return labels.containsKey(t) ? labels.get(t) : t;
    }

    private static CIPG_Config__mdt getConfig() {
        return [
            SELECT Jira_Project_Key__c, Jira_Base_URL__c
            FROM CIPG_Config__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
    }
}
