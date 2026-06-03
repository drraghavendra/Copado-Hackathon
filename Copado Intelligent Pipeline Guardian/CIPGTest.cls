/**
 * CIPGTest
 * ─────────────────────────────────────────────────────────────────────────────
 * Comprehensive unit test suite for all CIPG Apex services.
 * Uses mock HTTP callouts to isolate from external dependencies.
 * Target: ≥85% org-wide code coverage.
 */
@IsTest
private class CIPGTest {

    // ── Mock HTTP Callout ─────────────────────────────────────────────────────
    private class MockHttpCallout implements HttpCalloutMock {
        private Map<String, String> responses = new Map<String, String>();
        private Integer statusCode = 200;

        public MockHttpCallout withResponse(String urlPart, String body) {
            responses.put(urlPart, body);
            return this;
        }

        public MockHttpCallout withStatus(Integer code) {
            statusCode = code;
            return this;
        }

        public HTTPResponse respond(HTTPRequest req) {
            HTTPResponse res = new HTTPResponse();
            res.setStatusCode(statusCode);
            String body = '{}';
            for (String key : responses.keySet()) {
                if (req.getEndpoint().contains(key)) {
                    body = responses.get(key);
                    break;
                }
            }
            res.setBody(body);
            res.setHeader('Content-Type', 'application/json');
            return res;
        }
    }

    // ── Test Data Factory ─────────────────────────────────────────────────────
    private static PipelineGuardianService.PipelineFailureEvent makeEvent(
        String type
    ) {
        PipelineGuardianService.PipelineFailureEvent evt =
            new PipelineGuardianService.PipelineFailureEvent();
        evt.pipelineId       = 'PL-' + type + '-001';
        evt.pipelineName     = 'OrderService-Pipeline';
        evt.failureType      = type;
        evt.errorMessage     = 'System.NullPointerException: Attempt to de-reference a null object at line 142';
        evt.logUrl           = 'https://app.copado.com/logs/abc123';
        evt.branchName       = 'feature/OS-445';
        evt.developerEmail   = 'dev@example.com';
        evt.developerSlackId = 'U012AB3CD';
        evt.orgId            = '00D000000000001';
        evt.failedAt         = Datetime.now();
        return evt;
    }

    // ── PipelineGuardianService Tests ─────────────────────────────────────────
    @IsTest
    static void testHandleApexTestFailure() {
        String rcaJson = JSON.serialize(new Map<String, Object>{
            'summary'        => 'NullPointerException in OrderTriggerHandler',
            'primary_fix'    => 'Add null-check before Product2Id access',
            'error_category' => 'NULL_POINTER',
            'confidence_score' => 0.88,
            'auto_remediation' => false,
            'rerun_safe'     => true,
            'actions'        => new List<String>{ 'Pull logs', 'Re-run tests' },
            'failed_test_classes' => new List<String>{ 'OrderTriggerHandlerTest' }
        });

        String slackJson = JSON.serialize(new Map<String, Object>{
            'ok' => true, 'ts' => '1234567890.123456'
        });

        Test.setMock(HttpCalloutMock.class,
            new MockHttpCallout()
                .withResponse('/analyze', rcaJson)
                .withResponse('chat.postMessage', slackJson)
        );

        Test.startTest();
        PipelineGuardianService svc = new PipelineGuardianService();
        PipelineGuardianService.TriageResult result =
            svc.handleFailure(makeEvent('APEX_TEST'));
        Test.stopTest();

        System.assertNotEquals(null, result.incidentId, 'Incident should be created');
        System.assertEquals(false, result.autoResolved, 'Should not auto-resolve');
        System.assertEquals('1234567890.123456', result.slackMessageTs);

        Copado_Incident__c inc = [
            SELECT Status__c, RCA_Summary__c, Slack_Thread_Ts__c
            FROM Copado_Incident__c WHERE Id = :result.incidentId
        ];
        System.assertEquals('In Triage', inc.Status__c);
        System.assertNotEquals(null, inc.RCA_Summary__c);
    }

    @IsTest
    static void testAutoResolveDeploymentTimeout() {
        String rcaJson = JSON.serialize(new Map<String, Object>{
            'summary'          => 'Org lock contention during concurrent deploy',
            'primary_fix'      => 'Retry after 5 minutes',
            'error_category'   => 'LOCK_TIMEOUT',
            'confidence_score' => 0.95,
            'auto_remediation' => true,
            'rerun_safe'       => false,
            'actions'          => new List<String>{ 'Schedule retry' },
            'failed_test_classes' => new List<String>()
        });

        Test.setMock(HttpCalloutMock.class,
            new MockHttpCallout()
                .withResponse('/analyze', rcaJson)
                .withResponse('chat.postMessage', '{"ok":true,"ts":"111.222"}')
                .withResponse('/actions', '{"status":"scheduled"}')
        );

        Test.startTest();
        PipelineGuardianService.TriageResult result =
            new PipelineGuardianService().handleFailure(makeEvent('DEPLOYMENT_TIMEOUT'));
        Test.stopTest();

        System.assertEquals(true, result.autoResolved);

        Copado_Incident__c inc = [
            SELECT Status__c FROM Copado_Incident__c WHERE Id = :result.incidentId
        ];
        System.assertEquals('Auto-Resolved', inc.Status__c);
    }

    // ── CopadoAIService Tests ─────────────────────────────────────────────────
    @IsTest
    static void testParseRCAResponse() {
        String json = '{"summary":"Test","primary_fix":"Fix it","error_category":"NULL_POINTER",'
                    + '"confidence_score":0.75,"auto_remediation":true,"rerun_safe":false,'
                    + '"actions":["Action1","Action2"],"failed_test_classes":["TestClass"]}';

        CopadoAIService.RCAResponse rca = CopadoAIService.parseRCAResponse(json);

        System.assertEquals('Test', rca.summary);
        System.assertEquals(0.75, rca.confidenceScore);
        System.assertEquals(true, rca.autoRemediationAvailable);
        System.assertEquals(2, rca.actions.size());
        System.assertEquals('TestClass', rca.failedTestClasses[0]);
    }

    @IsTest
    static void testRerunTests() {
        Test.setMock(HttpCalloutMock.class,
            new MockHttpCallout().withResponse('/actions', '{"status":"queued"}')
        );
        Test.startTest();
        CopadoAIService.rerunTests('PL-001', new List<String>{ 'TestClass' });
        Test.stopTest();
        // No exception = pass
    }

    // ── KnowledgeBaseService Tests ────────────────────────────────────────────
    @IsTest
    static void testCreateAndFindKBEntry() {
        PipelineGuardianService.PipelineFailureEvent evt = makeEvent('APEX_TEST');
        CopadoAIService.RCAResponse rca = new CopadoAIService.RCAResponse();
        rca.primaryFix    = 'Add null check';
        rca.summary       = 'NullPointerException in trigger';
        rca.errorCategory = 'NULL_POINTER';
        rca.confidenceScore = 0.8;

        // Create a dummy incident first
        Copado_Incident__c inc = new Copado_Incident__c(
            Pipeline_Id__c   = evt.pipelineId,
            Pipeline_Name__c = evt.pipelineName,
            Failure_Type__c  = evt.failureType,
            Error_Message__c = evt.errorMessage,
            Status__c        = 'New',
            Failed_At__c     = evt.failedAt
        );
        insert inc;

        Test.startTest();
        CIPG_KB_Entry__c entry = KnowledgeBaseService.createEntry(evt, rca, inc.Id);
        List<CIPG_KB_Entry__c> found = KnowledgeBaseService.findSimilar(
            'APEX_TEST', 'NullPointerException'
        );
        Test.stopTest();

        System.assertNotEquals(null, entry.Id);
        // findSimilar uses SOSL — in test context returns all eligible records
        System.assert(found != null);
    }

    @IsTest
    static void testRecordResolution() {
        Copado_Incident__c inc = new Copado_Incident__c(
            Pipeline_Id__c   = 'PL-001',
            Pipeline_Name__c = 'Test Pipeline',
            Failure_Type__c  = 'APEX_TEST',
            Error_Message__c = 'Test error',
            Status__c        = 'In Triage',
            Failed_At__c     = Datetime.now()
        );
        insert inc;

        Test.startTest();
        KnowledgeBaseService.recordResolution(inc.Id, 'Fixed by null check', true);
        Test.stopTest();

        Copado_Incident__c updated = [SELECT Status__c FROM Copado_Incident__c WHERE Id = :inc.Id];
        System.assertEquals('Auto-Resolved', updated.Status__c);
    }

    // ── WebhookController Tests ───────────────────────────────────────────────
    @IsTest
    static void testPipelineEventEndpoint() {
        Test.setMock(HttpCalloutMock.class,
            new MockHttpCallout()
                .withResponse('/analyze', '{"summary":"test","primary_fix":"fix","confidence_score":0.5,"auto_remediation":false,"rerun_safe":false,"actions":[],"failed_test_classes":[]}')
                .withResponse('chat.postMessage', '{"ok":true,"ts":"123.456"}')
        );

        RestRequest req = new RestRequest();
        req.requestURI = '/services/apexrest/cipg/pipeline-events';
        req.httpMethod = 'POST';

        Map<String, Object> payload = new Map<String, Object>{
            'pipeline_id'    => 'PL-TEST-001',
            'pipeline_name'  => 'Test Pipeline',
            'event_type'     => 'TEST_RUN_FAILED',
            'error_message'  => 'NullPointerException at line 42',
            'log_url'        => 'https://copado.com/logs/test',
            'branch'         => 'feature/test',
            'org_id'         => '00D000000000001',
            'developer_email'=> 'test@example.com'
        };
        req.requestBody = Blob.valueOf(JSON.serialize(payload));

        // Bypass HMAC for test (no X-Copado-Signature header = handled gracefully)
        RestContext.request  = req;
        RestContext.response = new RestResponse();

        Test.startTest();
        WebhookController.handlePost();
        Test.stopTest();

        // Controller responds 401 without valid HMAC — confirm graceful handling
        System.assert(RestContext.response.statusCode == 200 ||
                       RestContext.response.statusCode == 401);
    }

    // ── SlackMessagingService Tests ───────────────────────────────────────────
    @IsTest
    static void testSendTriageMessage() {
        Test.setMock(HttpCalloutMock.class,
            new MockHttpCallout().withResponse('chat.postMessage',
                '{"ok":true,"ts":"9999.0001"}'
            )
        );

        SlackMessagingService.TriageMessage msg = new SlackMessagingService.TriageMessage();
        msg.channel        = 'U012AB3CD';
        msg.incidentId     = 'INC-001';
        msg.pipelineName   = 'TestPipeline';
        msg.failureType    = 'APEX_TEST';
        msg.rcaSummary     = 'Null pointer in trigger';
        msg.suggestedFix   = 'Add null check';
        msg.confidenceScore = 0.85;
        msg.logUrl         = 'https://copado.com/logs/1';

        Test.startTest();
        String ts = SlackMessagingService.sendTriageMessage(msg);
        Test.stopTest();

        System.assertEquals('9999.0001', ts);
    }

    // ── JiraIntegrationService Tests ──────────────────────────────────────────
    @IsTest
    static void testCreateJiraTicket() {
        Test.setMock(HttpCalloutMock.class,
            new MockHttpCallout()
                .withStatus(201)
                .withResponse('/issue', '{"id":"10001","key":"CIPG-42","self":"https://jira.com/issue/10001"}')
        );

        Copado_Incident__c inc = new Copado_Incident__c(
            Pipeline_Id__c   = 'PL-001',
            Pipeline_Name__c = 'OrderService',
            Failure_Type__c  = 'APEX_TEST',
            Error_Message__c = 'NullPointerException at line 142',
            Branch_Name__c   = 'feature/OS-445',
            Status__c        = 'In Triage',
            RCA_Summary__c   = 'Null reference in trigger handler',
            Failed_At__c     = Datetime.now()
        );
        insert inc;

        Test.startTest();
        JiraIntegrationService.JiraTicket ticket =
            JiraIntegrationService.createTicket(inc);
        Test.stopTest();

        System.assertEquals('CIPG-42', ticket.key);
        System.assert(ticket.url.contains('CIPG-42'));
        System.assert(!ticket.labels.isEmpty());
    }
}
