// The hosts cache: the adult-residents list the Guest Room and Common
// House modals show, kept fresh by its own Pusher channel and the
// reconnect recovery. One of the DataStore's subsystem files — see
// data_store.js, which composes them.
import axios from "axios";
import Cookie from "js-cookie";

import handleAxiosError from "../helpers/handle_axios_error";
import createVersionGuard from "../helpers/version_guard";

export function hostsVolatile() {
  return {
    // In-flight promise for the hosts fetch, so concurrent callers
    // (two modals opened in quick succession) don't trigger duplicate
    // network requests. Cleared when the fetch settles.
    hostsInFlight: null,
    // Stale-response guard for hosts fetches: a superseded fetch's
    // response is discarded in favor of the newer fetch's.
    hostsFetches: createVersionGuard(),
    // Single Pusher subscription for hosts updates. Assigned the first
    // time ensureHosts() succeeds; never resubscribed for the lifetime
    // of the store because the channel name only depends on community_id.
    hostsChannel: null,
  };
}

export function hostsActions(self) {
  return {
    // Guarantee the hosts list is loaded. Resolves immediately if the
    // cache is warm; otherwise kicks off a fetch (deduped against any
    // concurrent ensureHosts caller) and resolves when it lands.
    ensureHosts() {
      if (self.hostsLoaded) return Promise.resolve(self.hosts);
      return self._fetchHosts({ supersede: false });
    },
    // Refresh the hosts cache without clearing it first — the existing
    // array keeps rendering in any open modal until the new data arrives,
    // avoiding a flicker-to-empty. Used on Pusher update (residents changed
    // server-side) and Pusher reconnect (may have missed an update while
    // offline). Supersedes any in-flight ensureHosts fetch so we don't
    // serve a potentially-stale response.
    //
    // On failure: silently keeps the previously-loaded list visible. The
    // next Pusher `update` event (or reconnect) will re-trigger this path,
    // so transient network blips self-heal without user-visible errors.
    refetchHostsSilently() {
      return self._fetchHosts({ supersede: true });
    },
    // Internal: shared fetch implementation for ensureHosts and
    // refetchHostsSilently. Every call bumps the hostsFetches guard;
    // the resolve path discards a response whose token is stale.
    //
    //   supersede: false — dedupe onto any in-flight fetch
    //   supersede: true  — start a fresh fetch even if one is in flight;
    //                      the in-flight response will be version-skipped
    _fetchHosts(options = {}) {
      if (self.hostsInFlight && !options.supersede) return self.hostsInFlight;

      var versionAtStart = self.hostsFetches.bump();
      var communityId = Cookie.get("community_id");

      var promise = axios
        .get(`/api/v1/communities/${communityId}/hosts`)
        .then(function (response) {
          // Superseded by a later fetch: let the winner's response win.
          if (!self.hostsFetches.isCurrent(versionAtStart)) return self.hosts;
          if (response.status === 200) {
            self.setHosts(response.data);
            self.subscribeHostsChannel(communityId);
          }
          return self.hosts;
        })
        .catch(function (error) {
          handleAxiosError(error, { silent: true });
          return self.hosts;
        })
        .finally(function () {
          // Only clear the in-flight ref if we're still the reigning fetch.
          // A superseding fetch has already replaced `hostsInFlight` with
          // its own promise; don't trample it.
          if (self.hostsFetches.isCurrent(versionAtStart)) {
            self.setHostsInFlight(null);
          }
        });
      self.setHostsInFlight(promise);
      return promise;
    },
    // Transform the API's tuple shape ([residents.id, residents.name,
    // units.name]) into named-field objects at the store boundary so every
    // consumer reads host.id / host.name / host.unitName instead of cryptic
    // [0]/[1]/[2] indexing. The backend pluck order is set in
    // CommunitiesController#hosts — keep these in sync.
    setHosts(data) {
      var transformed = data.map(function (row) {
        return { id: row[0], name: row[1], unitName: row[2] };
      });
      self.hosts.replace(transformed);
      self.hostsLoadedAt = Date.now();
    },
    setHostsInFlight(promise) {
      self.hostsInFlight = promise;
    },
    subscribeHostsChannel(communityId) {
      if (self.hostsChannel) return;
      self.hostsChannel = window.Comeals.pusher.subscribe(
        `community-${communityId}-residents`,
      );
      self.hostsChannel.bind("update", function () {
        self.refetchHostsSilently();
      });
    },
  };
}
