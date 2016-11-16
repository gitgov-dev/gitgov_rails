//= require vue
//= require issuable_time_tracker
//= require smart_interval
//= require subbable_resource

(() => {
  /* This Vue instance represents what will become the parent instance for the
    * sidebar. It will be responsible for managing `issuable` state and propagating
    * changes to sidebar components.
   */

  class IssuableTimeTracking {
    constructor(issuableJSON) {
      const parsedIssuable = JSON.parse(issuableJSON);
      return this.initComponent(parsedIssuable);
    }

    initComponent(parsedIssuable) {
      this.parentInstance = new Vue({
        el: '#issuable-time-tracker',
        data: {
          issuable: parsedIssuable,
        },
        methods: {
          fetchIssuable() {
            return gl.IssuableResource.get.call(gl.IssuableResource, { type: 'GET', url: gl.IssuableResource.endpoint });
          },
          initPolling() {
            return new gl.SmartInterval({
              callback: this.fetchIssuable,
              startingInterval: 1000,
              maxInterval: 10000,
              incrementByFactorOf: 10,
              lazyStart: false
            });
          },
          updateState(data) {
            this.issuable = data;
          },
          subscribeToUpdates() {
            gl.IssuableResource.subscribe(data => this.updateState(data));
          },
          listenForSlashCommands() {
            $(document).on('ajax:success', '.gfm-form', () => {
              // TODO: check for slash command
              this.fetchIssuable();
            });
          },
        },
        created() {
          this.fetchIssuable();
        },
        mounted() {
          this.initPolling();
          this.subscribeToUpdates();
          this.listenForSlashCommands();
        },
      });
    }
  }

  gl.IssuableTimeTracking = IssuableTimeTracking;
})(window.gl || (window.gl = {}));
