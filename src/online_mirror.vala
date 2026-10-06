using GLib;
using Singularity.Accounts;

namespace Singularity.Apps.Tasks {

    public class OnlineMirror : Object {
        private CollectionTracker tracker;
        private Gee.ArrayList<ulong> handlers = new Gee.ArrayList<ulong> ();
        private uint queued = 0;

        public signal void changed ();

        public OnlineMirror () {
            tracker = CollectionTracker.get_shared (ContentKind.TASKS);
            handlers.add (tracker.set_added.connect (() => queue ()));
            handlers.add (tracker.set_removed.connect (() => queue ()));
            handlers.add (tracker.collections_changed.connect (() => queue ()));
            handlers.add (tracker.changed.connect (() => queue ()));
            handlers.add (tracker.notify["ready"].connect (() => queue ()));
            queue ();
        }

        public void stop () {
            foreach (ulong h in handlers) tracker.disconnect (h);
            handlers.clear ();
            if (queued != 0) Source.remove (queued);
            queued = 0;
        }

        private void queue () {
            if (queued != 0) return;
            queued = Timeout.add (300, () => {
                queued = 0;
                changed ();
                return Source.REMOVE;
            });
        }

        public static string list_id (Account account, SyncedCollection collection) {
            string hash = Checksum.compute_for_string (ChecksumType.SHA1, collection.remote.id);
            return "account-" + account.id + "-" + hash.substring (0, 12);
        }

        public void fill (TaskStore store) {
            if (!tracker.ready) return;
            var metadata = new TransferMetadata ();
            try {
                metadata.load ();
            } catch (Error e) {
                warning ("tasks: %s", e.message);
            }
            foreach (var set in tracker.get_sets ()) {
                var account = set.account;
                foreach (var c in set.collections) {
                    string id = list_id (account, c);
                    if (store.list (id) != null) continue;
                    var l = new TaskList (id, c.name != "" ? c.name : _("Tasks"));
                    l.account_id = account.id;
                    l.account_name = account.display_name;
                    l.icon_name = account.symbolic_icon_name;
                    l.read_only = c.read_only;
                    store.lists.add (l);
                    foreach (var item in c.items ()) {
                        if (item.state == SyncState.DELETED) continue;
                        string calname;
                        var parsed = ICal.parse (item.data, out calname);
                        if (parsed.size == 0) continue;
                        var t = parsed[0].task;
                        t.uid = item.uid;
                        t.list_id = id;
                        metadata.restore (t);
                        store.tasks.add (t);
                    }
                }
            }
        }
    }
}
