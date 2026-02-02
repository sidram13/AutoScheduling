public with sharing class FSSchedulerController {

    /**
     * Fetch active territories for the dashboard filter dropdown
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getServiceTerritoryOptions() {
        List<Map<String, String>> options = new List<Map<String, String>>();
        options.add(new Map<String, String>{'label' => 'All Territories', 'value' => ''});
        
        for (ServiceTerritory st : [SELECT Id, Name FROM ServiceTerritory WHERE IsActive = true ORDER BY Name]) {
            options.add(new Map<String, String>{'label' => st.Name, 'value' => st.Id});
        }
        return options;
    }

    /**
     * Run the assignment logic, optionally filtered by a specific territory
     */
    @AuraEnabled
    public static String runAutoAssign(String territoryId) {
        try {
            // 1. Fetch Appointments with conditional filter
            String saQuery = 'SELECT Id, ServiceTerritoryId, Status, SchedStartTime, SchedEndTime, ' +
                             'EarliestStartTime, Duration, ServiceTerritory.OperatingHoursId, ParentRecordId ' +
                             'FROM ServiceAppointment WHERE Status = \'None\' AND ServiceTerritoryId != null ';
            
            if (String.isNotBlank(territoryId)) {
                saQuery += ' AND ServiceTerritoryId = :territoryId ';
            }
            saQuery += ' ORDER BY CreatedDate ASC LIMIT 200';

            List<ServiceAppointment> saList = Database.query(saQuery);

            if (saList.isEmpty()) return 'No unassigned appointments found.';

            // 2. DATA GATHERING PHASE
            Set<Id> parentIds = new Set<Id>();
            Set<Id> territoryIds = new Set<Id>();
            Set<Id> ohIds = new Set<Id>();

            for(ServiceAppointment sa : saList) {
                parentIds.add(sa.ParentRecordId);
                territoryIds.add(sa.ServiceTerritoryId);
                if(sa.ServiceTerritory.OperatingHoursId != null) ohIds.add(sa.ServiceTerritory.OperatingHoursId);
            }

            Map<Id, Set<Id>> saRequiredSkillsMap = getRequiredSkills(parentIds);
            Map<Id, List<Id>> territoryMap = getTerritoryResourceMap(territoryIds);
            
            Set<Id> allTechIds = new Set<Id>();
            for(List<Id> ids : territoryMap.values()) allTechIds.addAll(ids);
            Map<Id, Set<Id>> techSkillsMap = getResourceSkills(allTechIds);

            Map<Id, Set<String>> ohValidDaysMap = new Map<Id, Set<String>>();
            Map<Id, Integer> ohStartMap = new Map<Id, Integer>();
            Map<Id, Integer> ohEndMap = new Map<Id, Integer>();
            fetchOperatingHours(ohIds, ohValidDaysMap, ohStartMap, ohEndMap);

            // 3. SCHEDULING PREPARATION
            Map<Id, Datetime> techLastEndTimeMap = new Map<Id, Datetime>();
            Map<Id, Integer> territoryTechIndexMap = new Map<Id, Integer>();
            List<AssignedResource> assignmentsToCreate = new List<AssignedResource>();
            List<ServiceAppointment> sasToUpdate = new List<ServiceAppointment>();

            // 4. DYNAMIC SCHEDULING LOOP
            for (ServiceAppointment sa : saList) {
                Id tId = sa.ServiceTerritoryId;
                if (!territoryMap.containsKey(tId)) continue;

                Set<Id> requiredSkills = saRequiredSkillsMap.get(sa.ParentRecordId);
                List<Id> allTechsInTerritory = territoryMap.get(tId);
                List<Id> qualifiedTechs = new List<Id>();

                for(Id techIdRef : allTechsInTerritory) {
                    Set<Id> heldSkills = techSkillsMap.get(techIdRef);
                    if (requiredSkills == null || (heldSkills != null && heldSkills.containsAll(requiredSkills))) {
                        qualifiedTechs.add(techIdRef);
                    }
                }

                if (qualifiedTechs.isEmpty()) continue;

                Integer currentIndex = territoryTechIndexMap.containsKey(tId) ? territoryTechIndexMap.get(tId) : 0;
                Id techId = qualifiedTechs[Math.mod(currentIndex, qualifiedTechs.size())];
                territoryTechIndexMap.put(tId, currentIndex + 1);

                Id ohId = sa.ServiceTerritory.OperatingHoursId;
                Integer workStart = ohStartMap.get(ohId) != null ? ohStartMap.get(ohId) : 8;
                Integer workEnd = ohEndMap.get(ohId) != null ? ohEndMap.get(ohId) : 17;
                Set<String> validDays = ohValidDaysMap.get(ohId);

                Datetime nextStart = techLastEndTimeMap.containsKey(techId) ? 
                                     techLastEndTimeMap.get(techId) : 
                                     (sa.EarliestStartTime != null ? sa.EarliestStartTime : DateTime.now());

                Integer safetyBreak = 0;
                while (safetyBreak < 14) {
                    String currentDay = nextStart.format('EEEE');
                    Integer currentHour = nextStart.hour();

                    if (validDays != null && !validDays.contains(currentDay)) {
                        nextStart = nextStart.addDays(1);
                        nextStart = Datetime.newInstance(nextStart.year(), nextStart.month(), nextStart.day(), workStart, 0, 0);
                        safetyBreak++; continue;
                    }
                    if (currentHour >= workEnd) {
                        nextStart = nextStart.addDays(1);
                        nextStart = Datetime.newInstance(nextStart.year(), nextStart.month(), nextStart.day(), workStart, 0, 0);
                        safetyBreak++; continue;
                    }
                    if (currentHour < workStart) {
                        nextStart = Datetime.newInstance(nextStart.year(), nextStart.month(), nextStart.day(), workStart, 0, 0);
                    }
                    break;
                }

                sa.SchedStartTime = nextStart;
                Double dur = (sa.Duration != null) ? sa.Duration : 1.0;
                sa.SchedEndTime = nextStart.addMinutes((Integer)(dur * 60));
                sa.Status = 'Scheduled';

                techLastEndTimeMap.put(techId, sa.SchedEndTime);
                assignmentsToCreate.add(new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = techId));
                sasToUpdate.add(sa);
            }

            if(!sasToUpdate.isEmpty()) update sasToUpdate;
            if(!assignmentsToCreate.isEmpty()) insert assignmentsToCreate;

            return 'Successfully processed ' + assignmentsToCreate.size() + ' appointments.';
        } catch (Exception e) {
            throw new AuraHandledException('Scheduling Error: ' + e.getMessage());
        }
    }

    /**
     * Fetch records for the UI cards with conditional territory filtering
     */
    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getServiceAppointments(String territoryId) {
        List<Map<String, Object>> results = new List<Map<String, Object>>();
        
        String query = 'SELECT Id, AppointmentNumber, Status, SchedStartTime, SchedEndTime, ' +
                       'ServiceTerritory.Name, (SELECT ServiceResource.Name FROM ServiceResources) ' +
                       'FROM ServiceAppointment WHERE Status != \'Completed\' ';
        
        if (String.isNotBlank(territoryId)) {
            query += ' AND ServiceTerritoryId = :territoryId ';
        }
        query += ' ORDER BY CreatedDate DESC LIMIT 100';

        for(ServiceAppointment sa : Database.query(query)) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('Id', sa.Id);
            row.put('AppointmentNumber', sa.AppointmentNumber);
            row.put('Status', sa.Status);
            row.put('SchedStartTime', sa.SchedStartTime);
            row.put('SchedEndTime', sa.SchedEndTime);
            row.put('TerritoryName', sa.ServiceTerritory != null ? sa.ServiceTerritory.Name : 'N/A');
            row.put('ResourceName', (sa.ServiceResources != null && !sa.ServiceResources.isEmpty()) ? sa.ServiceResources[0].ServiceResource.Name : 'Unassigned');
            row.put('cardStyle', (sa.Status == 'Scheduled' || sa.Status == 'Dispatched') ? 'background-color: #f0fff4; border-left: 5px solid #38a169;' : 'background-color: #fff5f5; border-left: 5px solid #e53e3e;');
            row.put('iconName', (sa.Status == 'Scheduled' || sa.Status == 'Dispatched') ? 'standard:event' : 'standard:choice');
            results.add(row);
        }
        return results;
    }

    // Helper methods (Keep existing implementations)
    private static Map<Id, Set<Id>> getRequiredSkills(Set<Id> parentIds) {
        Map<Id, Set<Id>> res = new Map<Id, Set<Id>>();
        for(SkillRequirement sr : [SELECT SkillId, RelatedRecordId FROM SkillRequirement WHERE RelatedRecordId IN :parentIds]) {
            if(!res.containsKey(sr.RelatedRecordId)) res.put(sr.RelatedRecordId, new Set<Id>());
            res.get(sr.RelatedRecordId).add(sr.SkillId);
        }
        return res;
    }

    private static Map<Id, Set<Id>> getResourceSkills(Set<Id> resourceIds) {
        Map<Id, Set<Id>> res = new Map<Id, Set<Id>>();
        for(ServiceResourceSkill srs : [SELECT SkillId, ServiceResourceId FROM ServiceResourceSkill WHERE ServiceResourceId IN :resourceIds AND (EffectiveEndDate = null OR EffectiveEndDate > :DateTime.now())]) {
            if(!res.containsKey(srs.ServiceResourceId)) res.put(srs.ServiceResourceId, new Set<Id>());
            res.get(srs.ServiceResourceId).add(srs.SkillId);
        }
        return res;
    }

    private static Map<Id, List<Id>> getTerritoryResourceMap(Set<Id> territoryIds) {
        Map<Id, List<Id>> tMap = new Map<Id, List<Id>>();
        for (ServiceTerritoryMember stm : [SELECT ServiceResourceId, ServiceTerritoryId FROM ServiceTerritoryMember WHERE ServiceTerritoryId IN :territoryIds AND ServiceResource.IsActive = true AND (EffectiveEndDate = null OR EffectiveEndDate > :DateTime.now())]) {
            if (!tMap.containsKey(stm.ServiceTerritoryId)) tMap.put(stm.ServiceTerritoryId, new List<Id>());
            tMap.get(stm.ServiceTerritoryId).add(stm.ServiceResourceId);
        }
        return tMap;
    }

    private static void fetchOperatingHours(Set<Id> ohIds, Map<Id, Set<String>> ohValidDaysMap, Map<Id, Integer> ohStartMap, Map<Id, Integer> ohEndMap) {
        for(TimeSlot ts : [SELECT OperatingHoursId, DayOfWeek, StartTime, EndTime FROM TimeSlot WHERE OperatingHoursId IN :ohIds]) {
            if(!ohValidDaysMap.containsKey(ts.OperatingHoursId)) ohValidDaysMap.put(ts.OperatingHoursId, new Set<String>());
            ohValidDaysMap.get(ts.OperatingHoursId).add(ts.DayOfWeek);
            if(!ohStartMap.containsKey(ts.OperatingHoursId) || ts.StartTime.hour() < ohStartMap.get(ts.OperatingHoursId)) ohStartMap.put(ts.OperatingHoursId, ts.StartTime.hour());
            if(!ohEndMap.containsKey(ts.OperatingHoursId) || ts.EndTime.hour() > ohEndMap.get(ts.OperatingHoursId)) ohEndMap.put(ts.OperatingHoursId, ts.EndTime.hour());
        }
    }
}