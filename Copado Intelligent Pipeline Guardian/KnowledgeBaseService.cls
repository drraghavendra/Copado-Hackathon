/**
 * KnowledgeBaseService
 * ─────────────────────────────────────────────────────────────────────────────
 * Manages the self-building troubleshooting knowledge base.
 * Stores error patterns and resolutions from every resolved incident,
 * enabling the Guardian to surface relevant past fixes instantly.
 */
public with sharing class KnowledgeBaseService {

    private static final Integer MAX_MATCHES = 3;

    /**
     * Find KB entries similar to the current failure.
     * Uses SOSL text search + failure type filter for relevance.
     */
    public static List<CIPG_KB_Entry__c> findSimilar(
        String failureType, String errorMessage
    ) {
        if (String.isBlank(errorMessage)) return new List<CIPG_KB_Entry__c>();

        // Extract key tokens from error message for SOSL
        String searchTerm = sanitizeForSOSL(extractKeyTerms(errorMessage));

        List<List<SObject>> results = [
            FIND :searchTerm IN ALL FIELDS
            RETURNING CIPG_KB_Entry__c(
                Id, Name, Error_Pattern__c, Resolution__c,
                Failure_Type__c, Occurrence_Count__c, Last_Seen__c,
                Confidence_Score__c, Apex_Class__c
                WHERE Failure_Type__c = :failureType
                ORDER BY Occurrence_Count__c DESC, Confidence_Score__c DESC
                LIMIT :MAX_MATCHES
            )
        ];

        return (List<CIPG_KB_Entry__c>) results[0];
    }

    /**
     * Create a new KB entry from a resolved incident.
     */
    public static CIPG_KB_Entry__c createEntry(
        PipelineGuardianService.PipelineFailureEvent evt,
        CopadoAIService.RCAResponse rca,
        String incidentId
    ) {
        CIPG_KB_Entry__c entry = new CIPG_KB_Entry__c(
            Name               = generateEntryName(evt),
            Error_Pattern__c   = extractKeyTerms(evt.errorMessage),
            Failure_Type__c    = evt.failureType,
            Resolution__c      = rca.primaryFix,
            RCA_Summary__c     = rca.summary,
            Error_Category__c  = rca.errorCategory,
            Confidence_Score__c = rca.confidenceScore,
            Occurrence_Count__c = 1,
            Last_Seen__c       = evt.failedAt,
            Source_Incident__c = incidentId,
            Pipeline_Name__c   = evt.pipelineName,
            Auto_Resolved__c   = false
        );
        insert entry;
        return entry;
    }

    /**
     * Record a resolution outcome — increments usage count,
     * boosts confidence if the fix worked.
     */
    public static void recordResolution(
        String incidentId, String resolution, Boolean autoResolved
    ) {
        // Find KB entries that were matched to this incident
        List<CIPG_KB_Match__c> matches = [
            SELECT Id, KB_Entry__c, KB_Entry__r.Occurrence_Count__c,
                   KB_Entry__r.Confidence_Score__c
            FROM CIPG_KB_Match__c
            WHERE Incident__c = :incidentId
            LIMIT 10
        ];

        List<CIPG_KB_Entry__c> toUpdate = new List<CIPG_KB_Entry__c>();
        for (CIPG_KB_Match__c m : matches) {
            CIPG_KB_Entry__c entry = m.KB_Entry__r;
            entry.Occurrence_Count__c =
                (entry.Occurrence_Count__c == null ? 0 : entry.Occurrence_Count__c) + 1;
            entry.Last_Seen__c  = Datetime.now();
            // Confidence decay/boost: resolution confirmed → +3%, else −5%
            Decimal delta = autoResolved ? 0.03 : -0.05;
            entry.Confidence_Score__c = Math.min(1.0, Math.max(0.0,
                (entry.Confidence_Score__c == null ? 0.5 : entry.Confidence_Score__c) + delta
            ));
            toUpdate.add(entry);
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }

        // Update the source incident
        Copado_Incident__c inc = new Copado_Incident__c(
            Id                 = incidentId,
            Resolution_Notes__c = resolution,
            Status__c          = autoResolved ? 'Auto-Resolved' : 'Resolved',
            Resolved_At__c     = Datetime.now()
        );
        update inc;
    }

    /**
     * Query KB entries for the LWC dashboard display.
     */
    public static List<CIPG_KB_Entry__c> getTopEntries(Integer limitCount) {
        return [
            SELECT Id, Name, Error_Pattern__c, Resolution__c,
                   Failure_Type__c, Occurrence_Count__c, Last_Seen__c,
                   Confidence_Score__c, Error_Category__c, Auto_Resolved__c
            FROM CIPG_KB_Entry__c
            ORDER BY Occurrence_Count__c DESC, Last_Seen__c DESC
            LIMIT :limitCount
        ];
    }

    // ── Private helpers ───────────────────────────────────────────────────────
    private static String extractKeyTerms(String errorMessage) {
        if (String.isBlank(errorMessage)) return '';
        // Pull class names, exception types, line references
        List<String> tokens = errorMessage.split('[\\s\\|:,]+');
        List<String> keyTerms = new List<String>();
        for (String t : tokens) {
            if (t.length() > 4 && !isStopWord(t)) {
                keyTerms.add(t);
            }
            if (keyTerms.size() >= 8) break;
        }
        return String.join(keyTerms, ' ');
    }

    private static String sanitizeForSOSL(String input) {
        // Escape special SOSL characters
        return input.replaceAll('[\\?\\&\\|\\!\\{\\}\\[\\]\\(\\)\\^\\~\\*\\:\\"\\'\\+\\-]', ' ').trim();
    }

    private static String generateEntryName(
        PipelineGuardianService.PipelineFailureEvent evt
    ) {
        String base = evt.failureType + '_' + evt.pipelineName;
        return (base.length() > 77 ? base.substring(0, 77) : base)
               + '_' + String.valueOf(Datetime.now().getTime()).right(5);
    }

    private static Boolean isStopWord(String w) {
        Set<String> stops = new Set<String>{
            'the','and','for','this','that','with','from','line',
            'class','System','null','error','Error','Exception'
        };
        return stops.contains(w);
    }
}
