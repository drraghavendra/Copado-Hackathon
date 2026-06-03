/**
 * CopadoAIService
 * ─────────────────────────────────────────────────────────────────────────────
 * Wraps the Copado AI Platform API for:
 *   • Root Cause Analysis (RCA) via NLP log parsing
 *   • Pipeline job control (re-run tests, schedule retry)
 *   • Streaming conversation context management
 *
 * Named Credential: CIPG_Copado_AI  (stored in Setup → Named Credentials)
 * Endpoint base  : callout:CIPG_Copado_AI/api/v1
 */
public with sharing class CopadoAIService {

    private static final String BASE_PATH = '/api/v1';
    private static final Integer TIMEOUT_MS = 30000;

    // ── Response DTOs ────────────────────────────────────────────────────────
    public class RCAResponse {
        public String  summary               { get; set; }
        public String  primaryFix            { get; set; }
        public Decimal confidenceScore       { get; set; }
        public List<String> actions          { get; set; }
        public List<String> failedTestClasses { get; set; }
        public Boolean autoRemediationAvailable { get; set; }
        public Boolean rerunSafe             { get; set; }
        public String  errorCategory         { get; set; } // NULL_POINTER | MISSING_FIELD | LOCK_TIMEOUT | SYNTAX
        public RCAResponse() {
            actions = new List<String>();
            failedTestClasses = new List<String>();
            autoRemediationAvailable = false;
            rerunSafe = false;
        }
    }

    public class ConversationMessage {
        public String role    { get; set; } // 'user' | 'assistant'
        public String content { get; set; }
    }

    public class ConversationResponse {
        public String message   { get; set; }
        public String threadId  { get; set; }
        public List<String> suggestedReplies { get; set; }
        public ConversationResponse() { suggestedReplies = new List<String>(); }
    }

    // ── Core: Analyze Failure via Copado AI API ──────────────────────────────
    public static RCAResponse analyzeFailure(
        PipelineGuardianService.PipelineFailureEvent evt,
        List<CIPG_KB_Entry__c> kbMatches
    ) {
        // Build KB context snippet for the prompt
        String kbContext = '';
        if (!kbMatches.isEmpty()) {
            List<String> entries = new List<String>();
            for (CIPG_KB_Entry__c kb : kbMatches) {
                entries.add('Previous incident: ' + kb.Error_Pattern__c +
                            ' | Resolution: ' + kb.Resolution__c);
            }
            kbContext = String.join(entries, '\n');
        }

        Map<String, Object> requestBody = new Map<String, Object>{
            'model'        => 'copado-ai-v2',
            'task'         => 'root_cause_analysis',
            'pipeline_id'  => evt.pipelineId,
            'failure_type' => evt.failureType,
            'error_message'=> evt.errorMessage,
            'log_url'      => evt.logUrl,
            'branch'       => evt.branchName,
            'kb_context'   => kbContext,
            'org_id'       => evt.orgId,
            'max_tokens'   => 1024
        };

        HttpResponse res = makeRequest('POST', '/analyze', requestBody);
        return parseRCAResponse(res.getBody());
    }

    // ── Conversational: Continue Triage Dialogue ─────────────────────────────
    public static ConversationResponse continueConversation(
        String threadId,
        String incidentId,
        List<ConversationMessage> history,
        String userMessage
    ) {
        List<Map<String, String>> messages = new List<Map<String, String>>();
        for (ConversationMessage m : history) {
            messages.add(new Map<String, String>{
                'role' => m.role, 'content' => m.content
            });
        }
        messages.add(new Map<String, String>{
            'role' => 'user', 'content' => userMessage
        });

        Map<String, Object> requestBody = new Map<String, Object>{
            'thread_id'   => threadId,
            'incident_id' => incidentId,
            'messages'    => messages,
            'task'        => 'conversational_triage'
        };

        HttpResponse res = makeRequest('POST', '/conversations', requestBody);
        return parseConversationResponse(res.getBody());
    }

    // ── Pipeline Actions ─────────────────────────────────────────────────────
    public static void rerunTests(String pipelineId, List<String> testClasses) {
        Map<String, Object> body = new Map<String, Object>{
            'pipeline_id'  => pipelineId,
            'action'       => 'rerun_tests',
            'test_classes' => testClasses
        };
        makeRequest('POST', '/pipelines/' + pipelineId + '/actions', body);
    }

    public static void scheduleRetry(String pipelineId) {
        Map<String, Object> body = new Map<String, Object>{
            'pipeline_id' => pipelineId,
            'action'      => 'schedule_retry',
            'delay_minutes' => 5
        };
        makeRequest('POST', '/pipelines/' + pipelineId + '/actions', body);
    }

    public static String fetchLogs(String pipelineId) {
        HttpResponse res = makeRequest('GET',
            '/pipelines/' + pipelineId + '/logs', null);
        Map<String, Object> body = (Map<String, Object>)
            JSON.deserializeUntyped(res.getBody());
        return (String) body.get('log_content');
    }

    // ── HTTP layer ───────────────────────────────────────────────────────────
    private static HttpResponse makeRequest(
        String method, String path, Map<String, Object> body
    ) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:CIPG_Copado_AI' + BASE_PATH + path);
        req.setMethod(method);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(TIMEOUT_MS);

        if (body != null) {
            req.setBody(JSON.serialize(body));
        }

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new PipelineGuardianService.GuardianException(
                'Copado AI API error ' + res.getStatusCode() +
                ': ' + res.getBody()
            );
        }
        return res;
    }

    // ── Parsers ──────────────────────────────────────────────────────────────
    @TestVisible
    private static RCAResponse parseRCAResponse(String json) {
        Map<String, Object> raw = (Map<String, Object>)
            JSON.deserializeUntyped(json);
        RCAResponse rca = new RCAResponse();
        rca.summary       = (String) raw.get('summary');
        rca.primaryFix    = (String) raw.get('primary_fix');
        rca.errorCategory = (String) raw.get('error_category');
        rca.confidenceScore = raw.containsKey('confidence_score')
            ? Decimal.valueOf(String.valueOf(raw.get('confidence_score'))) : 0.0;
        rca.autoRemediationAvailable =
            raw.containsKey('auto_remediation') &&
            (Boolean) raw.get('auto_remediation');
        rca.rerunSafe = raw.containsKey('rerun_safe') &&
            (Boolean) raw.get('rerun_safe');

        if (raw.containsKey('actions')) {
            for (Object a : (List<Object>) raw.get('actions')) {
                rca.actions.add((String) a);
            }
        }
        if (raw.containsKey('failed_test_classes')) {
            for (Object c : (List<Object>) raw.get('failed_test_classes')) {
                rca.failedTestClasses.add((String) c);
            }
        }
        return rca;
    }

    private static ConversationResponse parseConversationResponse(String json) {
        Map<String, Object> raw = (Map<String, Object>)
            JSON.deserializeUntyped(json);
        ConversationResponse resp = new ConversationResponse();
        resp.message  = (String) raw.get('message');
        resp.threadId = (String) raw.get('thread_id');
        if (raw.containsKey('suggested_replies')) {
            for (Object s : (List<Object>) raw.get('suggested_replies')) {
                resp.suggestedReplies.add((String) s);
            }
        }
        return resp;
    }
}
