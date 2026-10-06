using Singularity.Accounts;

namespace Singularity.Apps.Tasks {

    public class OnlineList : Object {
        public CollectionSet owner;
        public SyncedCollection collection;
        public TaskList list;
        public Gee.HashMap<string, Task> synced = new Gee.HashMap<string, Task> ();
        public Gee.HashMap<string, string> data = new Gee.HashMap<string, string> ();
        public Gee.HashMap<SyncItem, Task> items = new Gee.HashMap<SyncItem, Task> ();
        public Gee.ArrayList<ulong> handlers = new Gee.ArrayList<ulong> ();

        public OnlineList (CollectionSet owner, SyncedCollection collection, TaskList list) {
            this.owner = owner;
            this.collection = collection;
            this.list = list;
        }

        public void detach () {
            foreach (ulong h in handlers) collection.disconnect (h);
            handlers.clear ();
        }
    }

    public class OnlineTasks : Object {
        public TaskStore store { get; construct; }
        private CollectionTracker? tracker;
        private Gee.HashMap<string, OnlineList> lists = new Gee.HashMap<string, OnlineList> ();
        private uint rebuild_source;
        private TransferMetadata metadata = new TransferMetadata ();
        private bool transferring;

        public void load_metadata () throws Error {
            metadata.load ();
        }

        public void save_metadata () throws Error {
            if (transferring) return;
            metadata.update (store);
        }

        public Gee.List<CollectionSet> writable_accounts (bool transfer = false) {
            var result = new Gee.ArrayList<CollectionSet> ();
            if (tracker == null) return result;
            foreach (var owner in tracker.get_sets ()) {
                string api = Collections.api_for (owner.account, ContentKind.TASKS);
                if (owner.account.healthy && owner.account.has_capability (Capability.TASKS)
                    && (api == "google" || (!transfer && api == "graph"))) result.add (owner);
            }
            result.sort ((a, b) => strcmp (a.account.display_name, b.account.display_name));
            return result;
        }

        public async string create_list (CollectionSet owner, string name, Cancellable? cancellable = null) throws Error {
            var collection = yield owner.create (name, cancellable);
            rebuild ();
            return list_id_for (owner.account, collection);
        }

        public async string transfer_list (Storage storage, TaskList source, CollectionSet owner, Cancellable? cancellable = null) throws Error {
            if (transferring) throw new IOError.BUSY (_("Another list transfer is still running"));
            var transfer = new ListTransfer (store, storage, owner, source);
            transferring = true;
            try {
                string id = yield transfer.run (cancellable);
                metadata.load ();
                rebuild ();
                return id;
            } finally {
                transferring = false;
            }
        }

        public signal void changed ();
        public signal void task_updated (Task t);
        public signal void task_renamed (string old_uid, string new_uid);

        public OnlineTasks (TaskStore store) {
            Object (store: store);
        }

        public void start () {
            if (tracker != null) return;
            tracker = new CollectionTracker (ContentKind.TASKS);
            tracker.set_added.connect (() => queue_rebuild ());
            tracker.set_removed.connect (() => queue_rebuild ());
            tracker.collections_changed.connect (() => queue_rebuild ());
            tracker.changed.connect (() => queue_rebuild ());
            var manager = Manager.get_default ();
            manager.account_changed.connect (() => queue_rebuild ());
            manager.needs_attention.connect (() => queue_rebuild ());
            tracker.start.begin ((o, res) => {
                tracker.start.end (res);
                queue_rebuild ();
            });
        }

        public static string list_id_for (Account account, SyncedCollection collection) {
            string hash = Checksum.compute_for_string (ChecksumType.SHA1, collection.remote.id);
            return "account-" + account.id + "-" + hash.substring (0, 12);
        }

        public bool syncing (TaskList l) {
            var ol = lists[l.id];
            return ol != null && ol.collection.syncing;
        }

        public void sync_now (TaskList? l) {
            push ();
            var ol = l != null ? lists[l.id] : null;
            if (ol != null) {
                ol.collection.sync.begin ();
            } else if (tracker != null) {
                tracker.refresh_all.begin ();
            }
        }

        private void queue_rebuild () {
            if (rebuild_source != 0) return;
            rebuild_source = Idle.add (() => {
                rebuild_source = 0;
                rebuild ();
                return Source.REMOVE;
            });
        }

        private void rebuild () {
            if (tracker == null) return;
            push ();
            var wanted = new Gee.HashSet<string> ();
            foreach (var cs in tracker.get_sets ()) {
                foreach (var c in cs.collections) {
                    string id = list_id_for (cs.account, c);
                    wanted.add (id);
                    var ol = lists[id];
                    if (ol == null) {
                        ol = new OnlineList (cs, c, new TaskList (id, c.name));
                        ol.handlers.add (c.notify["syncing"].connect (() => queue_rebuild ()));
                        ol.handlers.add (c.notify["offline"].connect (() => queue_rebuild ()));
                        ol.handlers.add (c.notify["last-error"].connect (() => queue_rebuild ()));
                        lists[id] = ol;
                        store.lists.add (ol.list);
                    }
                    describe (ol);
                    import (ol);
                }
            }
            foreach (string id in lists.keys.to_array ()) {
                if (wanted.contains (id)) continue;
                var ol = lists[id];
                ol.detach ();
                lists.unset (id);
                var keep = new Gee.ArrayList<Task> ();
                foreach (var t in store.tasks) if (t.list_id != id) keep.add (t);
                store.tasks = keep;
                store.lists.remove (ol.list);
            }
            sort_lists ();
            changed ();
        }

        private void describe (OnlineList ol) {
            var account = ol.owner.account;
            var c = ol.collection;
            var l = ol.list;
            l.name = c.name != "" ? c.name : _("Tasks");
            l.account_id = account.id;
            l.account_name = account.display_name;
            l.icon_name = account.symbolic_icon_name;
            l.read_only = c.read_only;
            l.attention = !account.healthy;
            l.offline = account.healthy && c.offline;
            if (!account.healthy) l.status = _("Sign in again in Settings");
            else if (c.offline) l.status = _("Offline, changes will sync later");
            else if (c.last_error != "") l.status = _("Could not sync: %s").printf (c.last_error);
            else if (ol.owner.last_error != "" && c.last_sync == 0) l.status = _("Could not sync: %s").printf (ol.owner.last_error);
            else l.status = "";
        }

        private void sort_lists () {
            var local = new Gee.ArrayList<TaskList> ();
            var remote = new Gee.ArrayList<TaskList> ();
            foreach (var l in store.lists) {
                if (l.online) remote.add (l);
                else local.add (l);
            }
            remote.sort ((a, b) => {
                int c = strcmp (a.account_name.casefold (), b.account_name.casefold ());
                if (c == 0) c = strcmp (a.account_id, b.account_id);
                return c != 0 ? c : strcmp (a.name.casefold (), b.name.casefold ());
            });
            store.lists.clear ();
            store.lists.add_all (local);
            store.lists.add_all (remote);
        }

        private bool pending (OnlineList ol, Task t) {
            if (ol.list.read_only) return false;
            if (t.trashed) return true;
            var s = ol.synced[t.uid];
            return s == null || !same (s, t);
        }

        private void import (OnlineList ol) {
            var mine = new Gee.HashMap<string, Task> ();
            foreach (var t in store.tasks) if (t.list_id == ol.list.id) mine[t.uid] = t;
            var all = ol.collection.items ();
            var uids = new Gee.HashSet<string> ();
            foreach (var item in all) uids.add (item.uid);
            var keep = new Gee.HashSet<Task> ();
            var added = new Gee.ArrayList<Task> ();
            var live = new Gee.HashMap<SyncItem, Task> ();
            foreach (var item in all) {
                string calname;
                var parsed = ICal.parse (item.data, out calname);
                if (parsed.size == 0) continue;
                var fresh = parsed[0].task;
                fresh.uid = item.uid;
                fresh.list_id = ol.list.id;
                bool restored = metadata.restore (fresh);
                if (fresh.parent_uid == fresh.uid || !uids.contains (fresh.parent_uid)) fresh.parent_uid = "";
                Task? t = ol.items[item];
                if (t == null || t.list_id != ol.list.id || !store.tasks.contains (t)) t = mine[item.uid];
                if (t != null && t.uid != item.uid) rename (ol, t, item.uid);
                if (t == null) {
                    t = fresh;
                    t.list_id = ol.list.id;
                    store.tasks.add (t);
                    added.add (t);
                    ol.synced[t.uid] = snapshot (t);
                } else if (!pending (ol, t)) {
                    if (restored) t.position = fresh.position;
                    if (!same (t, fresh)) {
                        apply (fresh, t);
                        task_updated (t);
                    }
                    ol.synced[t.uid] = snapshot (t);
                }
                ol.data[t.uid] = item.data;
                live[item] = t;
                keep.add (t);
            }
            ol.items = live;
            foreach (var t in mine.values) {
                if (keep.contains (t) || pending (ol, t)) continue;
                store.tasks.remove (t);
                ol.synced.unset (t.uid);
                ol.data.unset (t.uid);
            }
            if (added.size == 0) return;
            int next = 0;
            foreach (var t in store.tasks) if (t.list_id == ol.list.id && !added.contains (t)) next = int.max (next, t.position + 1);
            added.sort ((a, b) => {
                if (a.completed != b.completed) return a.completed ? 1 : -1;
                int c = a.created.compare (b.created);
                return c != 0 ? c : strcmp (a.title.casefold (), b.title.casefold ());
            });
            foreach (var t in added) if (!metadata.restore (t)) t.position = next++;
        }

        private void rename (OnlineList ol, Task t, string uid) {
            string old = t.uid;
            foreach (var o in store.tasks) if (o.parent_uid == old) o.parent_uid = uid;
            t.uid = uid;
            var s = ol.synced[old];
            ol.synced.unset (old);
            if (s != null) {
                s.uid = uid;
                ol.synced[uid] = s;
            }
            string? d = ol.data[old];
            ol.data.unset (old);
            if (d != null) ol.data[uid] = d;
            task_renamed (old, uid);
        }

        public void push () {
            foreach (var ol in lists.values) push_list (ol);
        }

        private void push_list (OnlineList ol) {
            if (ol.list.read_only || ol.collection.syncing) return;
            var present = new Gee.HashSet<string> ();
            var gone = new Gee.ArrayList<Task> ();
            foreach (var t in store.tasks) {
                if (t.list_id != ol.list.id) continue;
                if (t.trashed) {
                    gone.add (t);
                    continue;
                }
                present.add (t.uid);
                var s = ol.synced[t.uid];
                if (s != null && same (s, t)) continue;
                string text = merge (ol.data[t.uid], s, t);
                ol.synced[t.uid] = snapshot (t);
                ol.data[t.uid] = text;
                ol.collection.put (t.uid, text);
                var item = ol.collection.get_item (t.uid);
                if (item != null) ol.items[item] = t;
            }
            foreach (var t in gone) store.tasks.remove (t);
            foreach (string uid in ol.synced.keys.to_array ()) {
                if (present.contains (uid)) continue;
                ol.synced.unset (uid);
                ol.data.unset (uid);
                ol.collection.remove (uid);
            }
        }

        private string merge (string? original, Task? s, Task t) {
            var single = new Gee.ArrayList<Task> ();
            single.add (t);
            var generated = Component.parse (ICal.export (single, store, null, new DateTime.now_utc ()));
            var gen = generated.get_child ("VTODO");
            gen.remove (ICal.LIST_PROPERTY);
            if (original == null || s == null) return generated.to_string ();
            var root = Component.parse (original);
            var todo = root != null ? root.get_child ("VTODO") : null;
            if (todo == null) return generated.to_string ();
            if (s.title != t.title) copy (gen, todo, "SUMMARY");
            if (s.notes != t.notes) copy (gen, todo, "DESCRIPTION");
            if (!same_time (s.due, t.due) || s.due_has_time != t.due_has_time) copy (gen, todo, "DUE");
            if (s.priority != t.priority) copy (gen, todo, "PRIORITY");
            if (s.tags_text () != t.tags_text ()) copy (gen, todo, "CATEGORIES");
            if (s.completed != t.completed || !same_time (s.completed_at, t.completed_at)) {
                copy (gen, todo, "STATUS");
                copy (gen, todo, "PERCENT-COMPLETE");
                copy (gen, todo, "COMPLETED");
            }
            if (s.rrule != t.rrule) copy (gen, todo, "RRULE");
            if (s.parent_uid != t.parent_uid) {
                var kept = new Gee.ArrayList<ContentLine> ();
                foreach (var l in todo.lines) {
                    string rel = (l.param ("RELTYPE") ?? "").up ();
                    if (l.name != "RELATED-TO" || (rel != "" && rel != "PARENT")) kept.add (l);
                }
                todo.lines = kept;
                foreach (var l in gen.get_lines ("RELATED-TO")) todo.lines.add (l);
            }
            if (s.reminder_minutes != t.reminder_minutes || !same_time (s.reminder_at, t.reminder_at)) {
                var children = new Gee.ArrayList<Component> ();
                foreach (var c in todo.children) if (c.name != "VALARM") children.add (c);
                foreach (var c in gen.children) if (c.name == "VALARM") children.add (c);
                todo.children = children;
            }
            copy (gen, todo, "LAST-MODIFIED");
            copy (gen, todo, "DTSTAMP");
            var sequence = todo.get_line ("SEQUENCE");
            if (sequence != null) sequence.value = (int.parse (sequence.value) + 1).to_string ();
            return root.to_string ();
        }

        private static void copy (Component from, Component to, string name) {
            to.remove (name);
            foreach (var l in from.get_lines (name)) to.lines.add (l);
        }

        private static bool same_time (DateTime? a, DateTime? b) {
            if (a == null || b == null) return a == b;
            return a.to_unix () == b.to_unix ();
        }

        private static bool same (Task a, Task b) {
            return a.title == b.title && a.notes == b.notes && same_time (a.due, b.due) && a.due_has_time == b.due_has_time
                && a.priority == b.priority && a.tags_text () == b.tags_text () && a.completed == b.completed
                && same_time (a.completed_at, b.completed_at) && a.rrule == b.rrule && a.parent_uid == b.parent_uid
                && a.reminder_minutes == b.reminder_minutes && same_time (a.reminder_at, b.reminder_at);
        }

        private static void apply (Task from, Task to) {
            to.title = from.title;
            to.notes = from.notes;
            to.due = from.due;
            to.due_has_time = from.due_has_time;
            to.priority = from.priority;
            to.tags.clear ();
            to.tags.add_all (from.tags);
            to.completed = from.completed;
            to.completed_at = from.completed_at;
            to.created = from.created;
            to.modified = from.modified;
            to.rrule = from.rrule;
            to.parent_uid = from.parent_uid;
            to.reminder_minutes = from.reminder_minutes;
            to.reminder_at = from.reminder_at;
            to.extra.clear ();
            to.extra.add_all (from.extra);
        }

        private static Task snapshot (Task t) {
            var s = new Task (t.uid);
            apply (t, s);
            return s;
        }
    }
}
