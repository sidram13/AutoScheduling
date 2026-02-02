# AutoScheduling Salesforce DX Project - Comprehensive Documentation

## 1. Overview

AutoScheduling is a Salesforce DX (SFDX) project that provides a lightweight Field Service scheduling dashboard and auto-assignment utility. It includes:

- A Lightning Web Component (LWC) fsDashboard that displays upcoming Service Appointments, allows filtering by Service Territory, and runs a bulk auto-assign action.
- An Apex controller FSSchedulerController that exposes UI data and implements a simple skill-aware, territory-aware round-robin scheduling routine.
- Basic project scaffolding for configuration, linting, formatting, and unit testing.

This documentation covers architecture, setup and deployment, detailed component/API contracts, data and security considerations, testing, and extensibility guidelines.

Repository name: AutoScheduling  
Source API Version: 65.0  
Primary Package Directory: force-app

## 2. Project Structure

High-level folders:
- force-app/main/default
  - classes
    - FSSchedulerController.cls (+ .cls-meta.xml)
  - lwc
    - fsDashboard
      - fsDashboard.html
      - fsDashboard.js
      - fsDashboard.js-meta.xml
      - __tests__/fsDashboard.test.js
  - applications, aura, contentassets, flexipages, layouts, objects, permissionsets, staticresources, tabs, triggers (currently empty or not used in logic)
- config/project-scratch-def.json (org definition)
- scripts/apex/hello.apex, scripts/soql/account.soql (sample scripts)
- sfdx-project.json (SFDX configuration)
- package.json, eslint.config.js, jest.config.js, .prettierrc (tooling config)

## 3. Setup and Deployment

Prerequisites:
- Salesforce CLI (sf) installed
- Access to a Dev Hub for scratch orgs or a target org for deploy
- Node.js for lint/test tooling

Scratch org workflow:
1) Create a scratch org
- sf org create scratch --definition-file config/project-scratch-def.json --alias AutoScheduling --duration-days 7 --set-default

2) Push source
- sf project deploy start --source-dir force-app

3) Assign permissions (if any are added later)
- sf org assign permset --name <PermsetName> --target-org AutoScheduling

4) Open org
- sf org open --target-org AutoScheduling

Deploy to a sandbox/production:
- Authenticate to target org:
  - Production: sf org login web --alias Prod
  - Sandbox: sf org login web --instance-url https://test.salesforce.com --alias MySandbox
- Deploy:
  - sf project deploy start --target-org MySandbox --source-dir force-app

Local tooling:
- Install dependencies: npm install
- Lint: npm run lint
- Format: npm run prettier
- Unit tests (LWC): npm run test:unit

## 4. Architecture

Layers:
- UI: Lightning Web Component fsDashboard
- Server: Apex FSSchedulerController (with sharing)
- Data: Standard Field Service objects (ServiceAppointment, ServiceTerritory, ServiceTerritoryMember, AssignedResource, ServiceResourceSkill, SkillRequirement, TimeSlot, OperatingHours via relationships)

Key interactions:
- fsDashboard wires to Apex:
  - getServiceAppointments(territoryId) to list dashboard cards
  - getServiceTerritoryOptions() to populate filter combobox
  - runAutoAssign(territoryId) to bulk-assign appointments
- Apex enforces sharing with with sharing. Queries are not using WITH SECURITY_ENFORCED and run in default system mode; consider enhancing security per org needs.

## 5. LWC: fsDashboard

Files:
- fsDashboard.html
- fsDashboard.js
- fsDashboard.js-meta.xml (targets Home and App pages)

Exposure:
- Targets: lightning__AppPage, lightning__HomePage
- apiVersion: 59.0
- isExposed: true

UI behavior:
- Card title: Field Service Dispatcher
- Actions:
  - Territory filter combobox
  - Run Auto-Assign button (brand)
  - Refresh Data button
- Content:
  - Spinner when isLoading
  - Grid of appointment cards (responsive: 1/2/3 columns at breakpoints)
  - Each card shows: Appointment Number (clickable to open in new tab), Territory, Status, Technician, Scheduled Slot (time range + date)
  - Empty state illustration when no appointments

Key properties and state:
- @track appointments: array of appointment DTOs returned from Apex
- @track territoryOptions: combobox options
- @track selectedTerritoryId: current filter value
- @track isLoading: disables actions + shows spinner
- wiredResult: stored wire context for refreshApex

Public contract: This component is self-contained, no public @api inputs/outputs.

Events:
- ShowToastEvent used for success/error notifications.

Navigation:
- Uses NavigationMixin.GenerateUrl to open the ServiceAppointment record page in a new browser tab.

Wiring:
- getSAs wired twice in code; the second definition overwrites the first. The effective wired handler sets this.appointments = result.data.
- getTerritoryOptions wired to populate the filter options.

Notable code issues and recommendations:
- Duplicate getter/getter and duplicate wire handler:
  - wiredAppointments is declared twice; remove the earlier duplicate to avoid confusion.
  - hasAppointments getter is declared twice; keep a single implementation:
    get hasAppointments() { return Array.isArray(this.appointments) && this.appointments.length > 0; }
- Record URL handling: First mapping added recordUrl; with the second wire it is not preserved. Either keep the mapping (use recordUrl) or rely only on handleNavigate to open records.

Testing:
- fsDashboard.test.js is a scaffold with a trivial assertion. Consider adding tests for:
  - Rendering of cards when wire data present
  - Empty state when no data
  - Territory filter change triggers wire re-evaluation
  - Auto-assign success and toast
  - Error paths for wires and actions
  - Navigation URL generation

## 6. Apex: FSSchedulerController

Class: public with sharing class FSSchedulerController

Exposed methods:
- @AuraEnabled(cacheable=true) public static List<Map<String, String>> getServiceTerritoryOptions()
  - Returns: list with first option { label: 'All Territories', value: '' } followed by active ServiceTerritory options { label: Name, value: Id }.
  - Query: ServiceTerritory WHERE IsActive = true ORDER BY Name

- @AuraEnabled public static String runAutoAssign(String territoryId)
  - Purpose: Bulk auto-assign unassigned ServiceAppointments (Status = 'None' and has ServiceTerritory) optionally filtered by specific ServiceTerritoryId. Limit 200 newest (by CreatedDate ASC).
  - Process:
    1) Query appointments
    2) Gather requirements and context:
       - ParentRecordId -> required skills from SkillRequirement
       - Territory -> resources from ServiceTerritoryMember (active, effective)
       - Resource -> skills from ServiceResourceSkill (effective)
       - Operating hours via TimeSlot by OperatingHoursId on ServiceTerritory
    3) Prepare round-robin scheduling mechanics (per territory index, last end time per technician)
    4) For each appointment:
       - Filter qualified technicians whose skills superset required skills
       - Round-robin selection among qualified technicians
       - Snap nextStart within operating hours and valid days (safety loop up to 14 iterations)
       - Set SchedStartTime, SchedEndTime (Duration hours -> minutes)
       - Set Status = 'Scheduled'
       - Create AssignedResource(ServiceAppointmentId, ServiceResourceId)
    5) Persist:
       - update appointments
       - insert assignments
    6) Return success message with number processed
  - Errors: Throws AuraHandledException('Scheduling Error: ' + e.getMessage())

- @AuraEnabled(cacheable=true) public static List<Map<String, Object>> getServiceAppointments(String territoryId)
  - Purpose: Return dashboard DTOs with key fields and presentation hints
  - Query: ServiceAppointment WHERE Status != 'Completed' optionally filtered by territory, includes subquery ServiceResources
  - Returned map keys:
    - Id, AppointmentNumber, Status, SchedStartTime, SchedEndTime
    - TerritoryName (from related ServiceTerritory)
    - ResourceName (first ServiceResource from subquery or 'Unassigned')
    - cardStyle (green for Scheduled/Dispatched, red otherwise)
    - iconName (standard:event or standard:choice)

Private helpers:
- getRequiredSkills(Set<Id> parentIds): Map<Id parentRecordId, Set<Id> skillIds>
- getResourceSkills(Set<Id> resourceIds): Map<Id resourceId, Set<Id> skillIds> (filters effective skills)
- getTerritoryResourceMap(Set<Id> territoryIds): Map<Id territoryId, List<Id> resourceIds> (active members, effective)
- fetchOperatingHours(Set<Id> ohIds, Map<Id, Set<String>> validDays, Map<Id, Integer> startHour, Map<Id, Integer> endHour): populates operating constraints using TimeSlot rows per OperatingHoursId

Security and limits considerations:
- with sharing is enabled; queries do not use WITH SECURITY_ENFORCED. Consider adding it for user-context reads.
- DML is bulkified (update list, insert list). Queries are outside loops. Good practices overall.
- Potential improvements: Use Database methods with AccessLevel.USER_MODE where appropriate for user-mode DML; validate FLS if required; consider platform eventing or Queueable for long-running batches.

Functional assumptions:
- Status 'None' represents unassigned appointments.
- Appointment Duration is in hours (Double); converted to minutes.
- Operates within ServiceTerritory Operating Hours (by TimeSlot min/max hours and allowed days).
- Assigns one technician via AssignedResource record per appointment.

## 7. Data Model Notes

Objects referenced:
- ServiceAppointment: AppointmentNumber, Status, SchedStartTime, SchedEndTime, EarliestStartTime, Duration, ServiceTerritoryId, ParentRecordId
- ServiceTerritory: Id, Name, OperatingHoursId, IsActive
- ServiceTerritoryMember: ServiceTerritoryId, ServiceResourceId, EffectiveEndDate, ServiceResource.IsActive
- AssignedResource: ServiceAppointmentId, ServiceResourceId
- SkillRequirement: SkillId, RelatedRecordId (ParentRecordId)
- ServiceResourceSkill: SkillId, ServiceResourceId, EffectiveEndDate
- TimeSlot: OperatingHoursId, DayOfWeek, StartTime, EndTime

Ensure Field Service features and related objects are enabled and licensed in target org.

## 8. Security, Sharing, and Compliance

Current state:
- Apex class uses with sharing.
- No FLS enforcement in queries (no WITH SECURITY_ENFORCED). If the dashboard runs for internal dispatcher profiles with broad access, this may be acceptable; otherwise add enforcement.

Recommendations aligned to internal rules:
- Prefer Database methods in USER_MODE for DML where user-level permissions should apply:
  - Database.update(records, AccessLevel.USER_MODE);
  - Database.insert(records, AccessLevel.USER_MODE);
- Use WITH SECURITY_ENFORCED on SOQL where feasible to honor FLS.
- Avoid SOQL/DML in loops (already respected).
- No hardcoded IDs/URLs are present.
- Consider custom permissions/permsets to gate the Run Auto-Assign action.

## 9. Configuration

Lightning App Builder:
- Add fsDashboard to a Home page or an App page (supported targets). Save and activate per profile/app as needed.

No custom metadata/settings are included in this repo. If needed, introduce:
- Custom Metadata Types for business hours or scheduling rules
- Custom Settings for thresholds and limits
- Permission Sets to control who can run bulk auto-assign

## 10. Testing

LWC:
- Test framework: @salesforce/sfdx-lwc-jest
- Commands:
  - npm run test:unit
  - npm run test:unit:watch
  - npm run test:unit:coverage
- Add tests for:
  - Rendering states (with and without data)
  - Click handlers (handleAutoAssign, handleRefresh, handleNavigate)
  - Toasts on success/error
  - Territory filter change

Apex:
- No Apex tests are included. Add tests covering:
  - getServiceTerritoryOptions: returns default option + active territories
  - getServiceAppointments: shapes DTO correctly; honors territory filter
  - runAutoAssign:
    - Creates AssignedResource and updates SA fields
    - Respects skills and operating hours
    - Skips when no qualified techs
    - Returns correct success message
    - Error handling path
  - Bulk test with multiple appointments and territories
  - Use @TestSetup for data, Test.startTest()/stopTest()

## 11. Operations and Usage

Dispatcher workflow:
1) Select a Territory in the combobox (or keep “All Territories”)
2) Click Run Auto-Assign to assign eligible unassigned Service Appointments
3) Review the updated cards; green cards indicate scheduled/dispatched
4) Click an Appointment Number to open the record in a new browser tab
5) Use Refresh Data to fetch latest statuses

Limits and performance:
- runAutoAssign limits to 200 SAs per execution (CreatedDate ASC). For larger volumes, consider:
  - Chunking by multiple executions
  - Queueable job for async processing
  - UI progress/notification via Platform Events

## 12. Extensibility Guidelines

General:
- Follow one-trigger-per-object and trigger handler patterns if triggers are added.
- Prefer Invocable Apex for Flow integration where possible.
- Avoid recursive triggers; bulkify all logic.

LWC:
- Consolidate duplicated wires/getters; keep component single-purpose.
- For complex reads, prefer LDS GraphQL (lightning/graphql) or standard LDS record adapters when feasible. Use Apex only when LDS is insufficient or server-side logic is required.

Apex:
- Consider introducing enums for statuses (e.g., SCHEDULING_STATUS) to avoid string literals.
- Extract scheduling strategy (round-robin) into a separate class implementing a Strategy/Command pattern for easier replacement (e.g., skill weight, travel time).
- Introduce dependency injection for testability where applicable.
- Add Database methods in USER_MODE when enforcing user permissions is desired.

Security:
- Add WITH SECURITY_ENFORCED to SOQL or validate FLS.
- Gate the auto-assign via Permission Set or Custom Permission.

Configuration:
- Add Custom Metadata Types to configure:
  - Status values for “unassigned”
  - Max daily hours per resource
  - Safety loop bounds
  - Territory or skill weighting

## 13. Known Issues and TODOs

- LWC fsDashboard duplicates wiredAppointments and hasAppointments definitions; consolidate to one each.
- LWC test file contains only a placeholder test.
- No Apex tests are present; required for deployment to production (75% overall coverage).
- fsDashboard.js-meta.xml apiVersion (59.0) is lower than project sourceApiVersion (65.0). Consider aligning.
- Queries do not use WITH SECURITY_ENFORCED; add if FLS needs to be enforced.
- DML uses default mode; consider Database.insert/update with AccessLevel.USER_MODE.
- No permission sets are defined to restrict access to the auto-assign action.

## 14. Reference Commands

Org lifecycle:
- sf org create scratch --definition-file config/project-scratch-def.json --alias AutoScheduling --duration-days 7 --set-default
- sf project deploy start --source-dir force-app
- sf org open

Unit tests:
- npm run test:unit
- npm run test:unit:coverage

Lint/format:
- npm run lint
- npm run prettier
- npm run prettier:verify

## 15. Appendix: File Inventory

Core source:
- force-app/main/default/classes/FSSchedulerController.cls
- force-app/main/default/classes/FSSchedulerController.cls-meta.xml
- force-app/main/default/lwc/fsDashboard/fsDashboard.html
- force-app/main/default/lwc/fsDashboard/fsDashboard.js
- force-app/main/default/lwc/fsDashboard/fsDashboard.js-meta.xml
- force-app/main/default/lwc/fsDashboard/__tests__/fsDashboard.test.js

Tooling and config:
- sfdx-project.json
- package.json
- jest.config.js
- eslint.config.js
- .prettierrc, .prettierignore
- .forceignore, .gitignore

Scripts:
- scripts/apex/hello.apex
- scripts/soql/account.soql

Empty/placeholder metadata folders:
- applications, aura, contentassets, flexipages, layouts, objects, permissionsets, staticresources, tabs, triggers
