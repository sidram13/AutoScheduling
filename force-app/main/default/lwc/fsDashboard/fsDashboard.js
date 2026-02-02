import { LightningElement, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getSAs from '@salesforce/apex/FSSchedulerController.getServiceAppointments';
import getTerritoryOptions from '@salesforce/apex/FSSchedulerController.getServiceTerritoryOptions';
import runAutoAssign from '@salesforce/apex/FSSchedulerController.runAutoAssign';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';



export default class FSDashboard extends NavigationMixin(LightningElement) {
    @track appointments = [];
    @track territoryOptions = [];
    @track selectedTerritoryId = '';
    @track isLoading = false;
    wiredResult;

    @wire(getSAs, { territoryId: '$selectedTerritoryId' })
    wiredAppointments(result) {
        this.wiredResult = result;
        if (result.data) {
            // We map the data to include a generated URL for each appointment
            this.appointments = result.data.map(sa => {
                return {
                    ...sa,
                    recordUrl: `/lightning/r/ServiceAppointment/${sa.Id}/view` // Direct link format
                };
            });
        }
    }

    // Fetch dropdown options for Territories
    @wire(getTerritoryOptions)
    wiredTerritories({ error, data }) {
        if (data) {
            this.territoryOptions = data;
        } else if (error) {
            this.showToast('Error', 'Failed to load territories', 'error');
        }
    }

    // Fetch Appointments reactively based on selected Territory
    @wire(getSAs, { territoryId: '$selectedTerritoryId' })
    wiredAppointments(result) {
        this.wiredResult = result;
        if (result.data) {
            this.appointments = result.data;
        }
    }

    get hasAppointments() {
        return this.appointments.length > 0;
    }

    handleFilterChange(event) {
        this.selectedTerritoryId = event.detail.value;
    }

    async handleAutoAssign() {
        this.isLoading = true;
        try {
            // Only assign appointments for the currently selected region
            const message = await runAutoAssign({ territoryId: this.selectedTerritoryId });
            await refreshApex(this.wiredResult);
            this.showToast('Bulk Assignment Complete', message, 'success');
        } catch (error) {
            this.showToast('Error', error.body.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async handleRefresh() {
        this.isLoading = true;
        await refreshApex(this.wiredResult);
        this.isLoading = false;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    handleNavigate(event) {
        const recordId = event.currentTarget.dataset.id; //

        // 1. Define the Page Reference
        const pageRef = {
            type: 'standard__recordPage',
            attributes: {
                recordId: recordId,
                actionName: 'view'
            }
        };

        // 2. Generate the URL and then open in new tab
        this[NavigationMixin.GenerateUrl](pageRef)
            .then(url => {
                window.open(url, '_blank'); // This forces the new tab
            });
    }

    // Add this inside your class in fsDashboard.js
get hasAppointments() {
    return this.appointments && this.appointments.length > 0;
}
}