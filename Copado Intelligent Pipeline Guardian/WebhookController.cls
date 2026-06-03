/**
 * WebhookController
 * ─────────────────────────────────────────────────────────────────────────────
 * Exposes two REST endpoints:
 *
 *   POST /services/apexrest/cipg/pipeline-events
 *     → Receives Copado CI/CD pipeline failure webhooks
 *
 *   POST /services/apexrest/cipg/slack-actions
 *     → Receives Slack interactive component payloads (button clicks)
 *
 * Both endpoints validate HMAC-SHA256 signatures before processing.
 * Runs without sharing to allow insert of incident records cross-user.
 */
@RestResource(urlMapping='/cipg/*')
global without sharing class WebhookController {

    // ── Copado Pipeline Event Endpoint ────────────────────────────────────────
    @HttpPost
    global static void handlePost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        try {
            String path = req.requestURI;

            if (path.endsWith('pipeline-events')) {
                handlePipelineEvent(req, res);
            } else if (path.endsWith('slack-actions')) {
                handleSlackAction(req, res);
            } else if (path.endsWith('conversation')) {
                handleConversationMessage(req, res);
            } else {
                res.statusCode = 404;
                res.responseBody = Blob.valueOf('{"error":"Unknown endpoint"}');
            }
        } catch (Exception ex) {
            res.statusCode = 500;
            res.responseBody = Blob.valueOf(
                '{"error":"' + ex.getMessage().replace('"', '\\"') + '"}'
            );
        }
    }

    // ── Pipeline event handler ────────────────────────────────────────────────
    private static void handlePipelineEvent(RestRequest req, RestResponse res) {
        // Validate Copado HMAC signature
        if (!validateHmac(req, getSecret('Copado_Webhook_Secret'))) {
            res.statusCode = 401;
            res.responseBody = Blob.valueOf('{"error":"Invalid signature"}');
            return;
        }

        String body = req.requestBody.toString();
        Map<String, Object> payload = (Map<String, Object>)
            JSON.deserializeUntyped(body);

        // Map Copado webhook payload → internal DTO
        PipelineGuardianService.PipelineFailureEvent evt =
            mapCopadoPayload(payload);

        // Dispatch async to avoid 5-second webhook response requirement
        PipelineGuardianService.handleFailureAsync(JSON.serialize(evt));

        res.statusCode = 200;
        res.responseBody = Blob.valueOf('{"status":"accepted","message":"Triage initiated"}');
    }

    // ── Slack action handler ──────────────────────────────────────────────────
    private static void handleSlackAction(RestRequest req, RestResponse res) {
        // Slack sends payload as URL-encoded form param
        String rawPayload = req.params.get('payload');
        if (String.isBlank(rawPayload)) {
            res.statusCode = 400;
            res.responseBody = Blob.valueOf('{"error":"Missing payload"}');
            return;
        }

        Map<String, Object> slackPayload = (Map<String, Object>)
            JSON.deserializeUntyped(EncodingUtil.urlDecode(rawPayload, 'UTF-8'));

        String actionId  = getNestedString(slackPayload, 'actions', 0, 'action_id');
        String value     = getNestedString(slackPayload, 'actions', 0, 'value');
        String channel   = getNestedString(slackPayload, 'channel', 'id');
        String threadTs  = (String) ((Map<String, Object>) slackPayload.get('message'))?.get('ts');
        String userId    = getNestedString(slackPayload, 'user', 'id');

        // Parse incidentId from value (format: "incidentId|action")
        List<String> parts = value.split('\\|');
        String incidentId = parts[0];
        String action     = parts.size() > 1 ? parts[1] : actionId;

        SlackActionService.handleActionAsync(
            incidentId, action, channel, threadTs, userId
        );

        // Respond immediately (Slack requires <3s)
        res.statusCode = 200;
        res.responseBody = Blob.valueOf(''); // empty = no immediate message update
    }

    // ── Conversation message handler (from LWC chat panel) ───────────────────
    private static void handleConversationMessage(RestRequest req, RestResponse res) {
        String body = req.requestBody.toString();
        Map<String, Object> payload = (Map<String, Object>)
            JSON.deserializeUntyped(body);

        String incidentId   = (String) payload.get('incident_id');
        String threadId     = (String) payload.get('thread_id');
        String userMessage  = (String) payload.get('message');

        // Fetch conversation history
        List<Copado_Conversation_Message__c> history = [
            SELECT Role__c, Content__c
            FROM Copado_Conversation_Message__c
            WHERE Incident__c = :incidentId
            ORDER BY CreatedDate ASC
            LIMIT 50
        ];

        List<CopadoAIService.ConversationMessage> msgs =
            new List<CopadoAIService.ConversationMessage>();
        for (Copado_Conversation_Message__c h : history) {
            CopadoAIService.ConversationMessage m =
                new CopadoAIService.ConversationMessage();
            m.role    = h.Role__c;
            m.content = h.Content__c;
            msgs.add(m);
        }

        // Store user message
        insert new Copado_Conversation_Message__c(
            Incident__c = incidentId,
            Role__c     = 'user',
            Content__c  = userMessage
        );

        // Call AI for response
        CopadoAIService.ConversationResponse aiRes =
            CopadoAIService.continueConversation(
                threadId, incidentId, msgs, userMessage
            );

        // Store AI response
        insert new Copado_Conversation_Message__c(
            Incident__c = incidentId,
            Role__c     = 'assistant',
            Content__c  = aiRes.message
        );

        res.statusCode = 200;
        res.responseBody = Blob.valueOf(JSON.serialize(aiRes));
    }

    // ── Payload mapper ────────────────────────────────────────────────────────
    private static PipelineGuardianService.PipelineFailureEvent mapCopadoPayload(
        Map<String, Object> p
    ) {
        PipelineGuardianService.PipelineFailureEvent evt =
            new PipelineGuardianService.PipelineFailureEvent();

        evt.pipelineId   = (String) p.get('pipeline_id');
        evt.pipelineName = (String) p.get('pipeline_name');
        evt.failureType  = mapCopadoEventType((String) p.get('event_type'));
        evt.errorMessage = (String) p.get('error_message');
        evt.logUrl       = (String) p.get('log_url');
        evt.branchName   = (String) p.get('branch');
        evt.orgId        = (String) p.get('org_id');
        evt.failedAt     = Datetime.now();

        // Resolve Slack ID from developer email via User lookup
        if (p.containsKey('developer_email')) {
            evt.developerEmail = (String) p.get('developer_email');
            List<User> users   = [
                SELECT Id, Slack_User_Id__c
                FROM User
                WHERE Email = :evt.developerEmail
                LIMIT 1
            ];
            if (!users.isEmpty()) {
                evt.developerSlackId = users[0].Slack_User_Id__c;
            }
        }

        return evt;
    }

    private static String mapCopadoEventType(String copadoType) {
        Map<String, String> typeMap = new Map<String, String>{
            'TEST_RUN_FAILED'        => 'APEX_TEST',
            'MERGE_CONFLICT'         => 'MERGE_CONFLICT',
            'DEPLOYMENT_FAILED'      => 'DEPLOYMENT_TIMEOUT',
            'DEPLOYMENT_TIMEOUT'     => 'DEPLOYMENT_TIMEOUT',
            'QUALITY_GATE_FAILED'    => 'STATIC_ANALYSIS',
            'STATIC_ANALYSIS_FAILED' => 'STATIC_ANALYSIS'
        };
        return typeMap.containsKey(copadoType) ? typeMap.get(copadoType) : copadoType;
    }

    // ── HMAC validation ───────────────────────────────────────────────────────
    private static Boolean validateHmac(RestRequest req, String secret) {
        String signature = req.headers.get('X-Copado-Signature');
        if (String.isBlank(signature) || String.isBlank(secret)) return false;

        Blob mac = Crypto.generateMac(
            'HmacSHA256',
            req.requestBody,
            Blob.valueOf(secret)
        );
        String expected = 'sha256=' + EncodingUtil.convertToHex(mac);
        return signature.equals(expected);
    }

    private static String getSecret(String devName) {
        List<CIPG_Config__mdt> cfg = [
            SELECT Value__c FROM CIPG_Config__mdt
            WHERE DeveloperName = :devName LIMIT 1
        ];
        return cfg.isEmpty() ? '' : cfg[0].Value__c;
    }

    // ── JSON navigation helpers ───────────────────────────────────────────────
    private static String getNestedString(
        Map<String, Object> m, String key1, String key2
    ) {
        Object l1 = m.get(key1);
        if (l1 instanceof Map<String, Object>) {
            return (String) ((Map<String, Object>) l1).get(key2);
        }
        return null;
    }

    private static String getNestedString(
        Map<String, Object> m, String listKey, Integer idx, String fieldKey
    ) {
        Object l = m.get(listKey);
        if (l instanceof List<Object>) {
            List<Object> list = (List<Object>) l;
            if (list.size() > idx && list[idx] instanceof Map<String, Object>) {
                return (String) ((Map<String, Object>) list[idx]).get(fieldKey);
            }
        }
        return null;
    }
}
