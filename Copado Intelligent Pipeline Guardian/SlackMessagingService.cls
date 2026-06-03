/**
 * SlackMessagingService
 * ─────────────────────────────────────────────────────────────────────────────
 * Sends and receives Slack Block Kit messages for pipeline incident triage.
 * Implements bi-directional communication:
 *   Guardian → Slack  : rich Block Kit cards with action buttons
 *   Slack → Guardian  : developer clicks routed back via SlackWebhookController
 *
 * Named Credential: CIPG_Slack_Bot  (Bot Token xoxb-...)
 */
public with sharing class SlackMessagingService {

    private static final String SLACK_POST_URL  = 'callout:CIPG_Slack_Bot/chat.postMessage';
    private static final String SLACK_UPDATE_URL = 'callout:CIPG_Slack_Bot/chat.update';
    private static final String SLACK_REPLY_URL  = 'callout:CIPG_Slack_Bot/chat.postMessage';

    // ── Inner DTO ─────────────────────────────────────────────────────────────
    public class TriageMessage {
        public String  channel         { get; set; }
        public String  incidentId      { get; set; }
        public String  pipelineName    { get; set; }
        public String  failureType     { get; set; }
        public String  rcaSummary      { get; set; }
        public String  suggestedFix    { get; set; }
        public Decimal confidenceScore { get; set; }
        public String  logUrl          { get; set; }
        public List<CIPG_KB_Entry__c> kbMatches { get; set; }
        public TriageMessage() { kbMatches = new List<CIPG_KB_Entry__c>(); }
    }

    // ── Send initial triage message ───────────────────────────────────────────
    public static String sendTriageMessage(TriageMessage msg) {
        Map<String, Object> payload = new Map<String, Object>{
            'channel' => msg.channel,
            'blocks'  => buildTriageBlocks(msg),
            'text'    => '🚨 Pipeline Failure: ' + msg.pipelineName
        };

        HttpResponse res = postToSlack(SLACK_POST_URL, payload);
        Map<String, Object> body = (Map<String, Object>)
            JSON.deserializeUntyped(res.getBody());

        if (!(Boolean) body.get('ok')) {
            throw new PipelineGuardianService.GuardianException(
                'Slack error: ' + body.get('error')
            );
        }
        return (String) body.get('ts'); // thread timestamp
    }

    // ── Send a follow-up reply in thread ─────────────────────────────────────
    public static void sendThreadReply(
        String channel, String threadTs, String message,
        List<Map<String, String>> actions
    ) {
        List<Object> blocks = new List<Object>{
            buildSection(message)
        };
        if (actions != null && !actions.isEmpty()) {
            blocks.add(buildActionBlock(actions));
        }

        Map<String, Object> payload = new Map<String, Object>{
            'channel'   => channel,
            'thread_ts' => threadTs,
            'blocks'    => blocks,
            'text'      => message
        };
        postToSlack(SLACK_REPLY_URL, payload);
    }

    // ── Update existing message (e.g., mark resolved) ────────────────────────
    public static void updateMessage(
        String channel, String ts, String statusText, String color
    ) {
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{
                'type' => 'section',
                'text' => new Map<String, Object>{
                    'type' => 'mrkdwn',
                    'text' => statusText
                }
            }
        };

        Map<String, Object> payload = new Map<String, Object>{
            'channel' => channel,
            'ts'      => ts,
            'blocks'  => blocks,
            'text'    => statusText
        };
        postToSlack(SLACK_UPDATE_URL, payload);
    }

    // ── Block Kit builders ────────────────────────────────────────────────────
    private static List<Object> buildTriageBlocks(TriageMessage msg) {
        String severityEmoji = getSeverityEmoji(msg.failureType);
        String confidencePct = String.valueOf(
            (msg.confidenceScore * 100).setScale(0)
        ) + '%';

        List<Object> blocks = new List<Object>{
            // Header
            new Map<String, Object>{
                'type' => 'header',
                'text' => new Map<String, Object>{
                    'type'  => 'plain_text',
                    'text'  => severityEmoji + ' Pipeline Failure — ' + msg.pipelineName,
                    'emoji' => true
                }
            },
            // Divider
            new Map<String, Object>{ 'type' => 'divider' },
            // Failure type + confidence
            new Map<String, Object>{
                'type'   => 'section',
                'fields' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'mrkdwn',
                        'text' => '*Failure Type*\n' + formatFailureType(msg.failureType)
                    },
                    new Map<String, Object>{
                        'type' => 'mrkdwn',
                        'text' => '*AI Confidence*\n' + confidencePct
                    },
                    new Map<String, Object>{
                        'type' => 'mrkdwn',
                        'text' => '*Incident ID*\n`' + msg.incidentId + '`'
                    },
                    new Map<String, Object>{
                        'type' => 'mrkdwn',
                        'text' => '*Detected*\n' + Datetime.now().format('HH:mm:ss') + ' UTC'
                    }
                }
            },
            // RCA Summary
            buildSection('*🔍 Root Cause Analysis*\n' + msg.rcaSummary),
            // Suggested fix
            buildSection('*💡 Suggested Fix*\n' + msg.suggestedFix)
        };

        // KB matches
        if (!msg.kbMatches.isEmpty()) {
            String kbText = '*📚 Similar Past Incidents Found*\n';
            for (CIPG_KB_Entry__c kb : msg.kbMatches) {
                kbText += '• `' + kb.Name + '` — ' + kb.Resolution__c + '\n';
            }
            blocks.add(buildSection(kbText));
        }

        blocks.add(new Map<String, Object>{ 'type' => 'divider' });

        // Action buttons
        blocks.add(buildActionBlock(new List<Map<String, String>>{
            new Map<String, String>{
                'id'    => 'pull_logs',
                'label' => '📋 Pull Full Logs',
                'style' => 'primary',
                'value' => msg.incidentId + '|pull_logs'
            },
            new Map<String, String>{
                'id'    => 'rerun_tests',
                'label' => '🔄 Re-run Tests',
                'style' => 'primary',
                'value' => msg.incidentId + '|rerun_tests'
            },
            new Map<String, String>{
                'id'    => 'create_jira',
                'label' => '🐛 Create Jira Ticket',
                'style' => 'default',
                'value' => msg.incidentId + '|create_jira'
            },
            new Map<String, String>{
                'id'    => 'dismiss',
                'label' => '✕ Dismiss',
                'style' => 'danger',
                'value' => msg.incidentId + '|dismiss'
            }
        }));

        // Log link
        if (String.isNotBlank(msg.logUrl)) {
            blocks.add(new Map<String, Object>{
                'type'     => 'context',
                'elements' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'mrkdwn',
                        'text' => '<' + msg.logUrl + '|View Full Copado Log> • Managed by CIPG Guardian'
                    }
                }
            });
        }

        return blocks;
    }

    private static Map<String, Object> buildSection(String text) {
        return new Map<String, Object>{
            'type' => 'section',
            'text' => new Map<String, Object>{
                'type'  => 'mrkdwn',
                'text'  => text
            }
        };
    }

    private static Map<String, Object> buildActionBlock(
        List<Map<String, String>> actions
    ) {
        List<Object> elements = new List<Object>();
        for (Map<String, String> a : actions) {
            Map<String, Object> btn = new Map<String, Object>{
                'type'  => 'button',
                'text'  => new Map<String, Object>{
                    'type'  => 'plain_text',
                    'text'  => a.get('label'),
                    'emoji' => true
                },
                'action_id' => a.get('id'),
                'value'     => a.get('value')
            };
            if (a.containsKey('style') && a.get('style') != 'default') {
                btn.put('style', a.get('style'));
            }
            elements.add(btn);
        }
        return new Map<String, Object>{
            'type'     => 'actions',
            'elements' => elements
        };
    }

    // ── Utilities ─────────────────────────────────────────────────────────────
    private static String getSeverityEmoji(String failureType) {
        Map<String, String> emojis = new Map<String, String>{
            'APEX_TEST'          => '🔴',
            'MERGE_CONFLICT'     => '🟡',
            'DEPLOYMENT_TIMEOUT' => '🔵',
            'STATIC_ANALYSIS'   => '🟣'
        };
        return emojis.containsKey(failureType) ? emojis.get(failureType) : '⚪';
    }

    private static String formatFailureType(String ft) {
        Map<String, String> labels = new Map<String, String>{
            'APEX_TEST'          => 'Apex Test Failure',
            'MERGE_CONFLICT'     => 'Merge Conflict',
            'DEPLOYMENT_TIMEOUT' => 'Deployment Timeout',
            'STATIC_ANALYSIS'   => 'Static Analysis'
        };
        return labels.containsKey(ft) ? labels.get(ft) : ft;
    }

    private static HttpResponse postToSlack(
        String endpoint, Map<String, Object> payload
    ) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json;charset=UTF-8');
        req.setBody(JSON.serialize(payload));
        req.setTimeout(10000);
        return new Http().send(req);
    }
}
