namespace Singularity.Apps.Tasks {

    [DBus (name = "dev.sinty.Collab.Task1")]
    public class TaskCollabBus : Object {
        private unowned TasksApp app;

        public TaskCollabBus (TasksApp app) {
            this.app = app;
        }

        public void receive (string title, string payload, string from) throws Error {
            app.hold ();
            try {
                app.collab.receive_task (payload, from);
            } finally {
                app.release ();
            }
        }

        public void join (string session, string title, string snapshot, string role, string from) throws Error {
            throw new IOError.NOT_SUPPORTED ("single tasks are not shared in a session");
        }
    }

    [DBus (name = "dev.sinty.Collab.TaskList1")]
    public class TaskListCollabBus : Object {
        private unowned TasksApp app;

        public TaskListCollabBus (TasksApp app) {
            this.app = app;
        }

        public void receive (string title, string payload, string from) throws Error {
            throw new IOError.NOT_SUPPORTED ("lists are shared in a session");
        }

        public void join (string session, string title, string snapshot, string role, string from) throws Error {
            app.collab.join_list (session, title, snapshot, from);
        }
    }

    public class TasksCollab : Object {
        private const string NAME_KEY = "~name";

        private class Link {
            public string list_id;
            public Singularity.Collab.Document doc;
            public Singularity.Collab.Session session;
            public Singularity.Collab.UnitsBinding binding;
            public string host = "";
        }

        private unowned TasksApp app;
        private string state_path;
        private Gee.HashMap<string, Link> links = new Gee.HashMap<string, Link> ();
        private uint save_id = 0;

        public signal void status (string message);

        public TasksCollab (TasksApp app) {
            this.app = app;
            state_path = Path.build_filename (Path.get_dirname (Storage.default_path ()), "shared-lists.json");
            app.store.changed.connect (() => {
                foreach (var l in links.values) l.binding.local_changed ();
                queue_save ();
            });
        }

        public static bool available () {
            return Singularity.Collab.Client.installed ();
        }

        public bool is_shared (string list_id) {
            return links.has_key (list_id);
        }

        public bool hosting (string list_id) {
            var l = links[list_id];
            return l != null && l.session.hosting;
        }

        public static Json.Object task_json (Task t) {
            var o = new Json.Object ();
            o.set_string_member ("title", t.title);
            if (t.notes != "") o.set_string_member ("notes", t.notes);
            if (t.parent_uid != "") o.set_string_member ("parent", t.parent_uid);
            if (t.due != null) o.set_string_member ("due", Storage.format_date (t.due, t.due_has_time));
            if (t.priority != Priority.NONE) o.set_int_member ("priority", (int) t.priority);
            if (t.tags.size > 0) {
                var tags = new Json.Array ();
                foreach (string tag in t.tags) tags.add_string_element (tag);
                o.set_array_member ("tags", tags);
            }
            o.set_boolean_member ("completed", t.completed);
            if (t.completed_at != null) o.set_string_member ("completed_at", t.completed_at.format_iso8601 ());
            o.set_int_member ("position", t.position);
            if (t.rrule != "") o.set_string_member ("rrule", t.rrule);
            if (t.reminder_minutes >= 0) o.set_int_member ("reminder_minutes", t.reminder_minutes);
            return o;
        }

        public static void apply_json (Task t, Json.Object o) {
            t.title = o.get_string_member_with_default ("title", "");
            t.notes = o.get_string_member_with_default ("notes", "");
            t.parent_uid = o.get_string_member_with_default ("parent", "");
            bool with_time;
            t.due = Storage.parse_date (o.get_string_member_with_default ("due", ""), out with_time);
            t.due_has_time = with_time;
            t.priority = (Priority) ((int) o.get_int_member_with_default ("priority", 0)).clamp (0, 3);
            t.tags.clear ();
            if (o.has_member ("tags")) {
                foreach (var tag in o.get_array_member ("tags").get_elements ()) t.tags.add (tag.get_string ());
            }
            t.completed = o.get_boolean_member_with_default ("completed", false);
            string done_at = o.get_string_member_with_default ("completed_at", "");
            t.completed_at = done_at != "" ? new DateTime.from_iso8601 (done_at, null) : null;
            t.position = (int) o.get_int_member_with_default ("position", t.position);
            t.rrule = o.get_string_member_with_default ("rrule", "");
            t.reminder_minutes = (int) o.get_int_member_with_default ("reminder_minutes", -1);
            t.modified = new DateTime.now_utc ();
        }

        private Gee.Map<string, string> units (string list_id) {
            var map = new Gee.HashMap<string, string> ();
            var l = app.store.list (list_id);
            if (l == null) return map;
            map[NAME_KEY] = l.name;
            foreach (var t in app.store.tasks) {
                if (t.list_id != list_id || t.trashed) continue;
                map[t.uid] = Singularity.Collab.Shared.encode (task_json (t));
            }
            return map;
        }

        private void apply_units (string list_id, Gee.Map<string, string?> changed, string author) {
            var l = app.store.list (list_id);
            if (l == null) return;
            var now = new DateTime.now_utc ();
            foreach (var e in changed.entries) {
                if (e.key == NAME_KEY) {
                    if (e.value != null && e.value != "") l.name = e.value;
                    continue;
                }
                var t = app.store.find (e.key);
                if (e.value == null) {
                    if (t != null && t.list_id == list_id && !t.trashed) app.store.trash (t, now);
                    continue;
                }
                var o = Singularity.Collab.Shared.decode (e.value);
                if (o == null) continue;
                if (t == null) {
                    t = new Task (e.key);
                    t.list_id = list_id;
                    t.created = now;
                    app.store.tasks.add (t);
                } else if (t.list_id != list_id) {
                    continue;
                } else if (t.trashed) {
                    app.store.restore (t);
                }
                apply_json (t, o);
            }
            app.store.notify_changed ();
            app.schedule_save ();
        }

        private Link bind (string list_id, Singularity.Collab.Document doc, string title) {
            var l = new Link ();
            l.list_id = list_id;
            l.doc = doc;
            l.session = new Singularity.Collab.Session ("TaskList", title, doc);
            string id = list_id;
            l.binding = new Singularity.Collab.UnitsBinding (doc, () => units (id), (changed, who) => apply_units (id, changed, who));
            doc.changed.connect (() => queue_save ());
            l.session.person_joined.connect ((name) => status (_("%s joined the list").printf (name)));
            l.session.person_left.connect ((name) => status (_("%s left the list").printf (name)));
            l.session.closed.connect (() => {
                links.unset (id);
                queue_save ();
                status (_("The list is no longer shared"));
            });
            links[list_id] = l;
            return l;
        }

        public void share_list (TaskList list, Gtk.Widget anchor) {
            var l = links[list.id];
            if (l == null) {
                var doc = new Singularity.Collab.Document ();
                doc.load_values (units (list.id));
                l = bind (list.id, doc, list.name);
            }
            l.session.pick_and_share (anchor, (person) => {
                queue_save ();
                status (_("Invitation sent to %s").printf (person.name));
            });
        }

        public void stop (string list_id) {
            var l = links[list_id];
            if (l != null) l.session.stop.begin ();
        }

        public void send_task (Task t, Gtk.Widget anchor) {
            string text = t.notes != "" ? "%s\n\n%s".printf (t.title, t.notes) : t.title;
            Singularity.Collab.send_to (anchor, "Task", t.title, Singularity.Collab.Shared.encode (task_json (t)), text, (person) => {
                status (_("Sent to %s").printf (person.name));
            });
        }

        public void receive_task (string payload, string from) throws Error {
            var o = Singularity.Collab.Shared.decode (payload);
            if (o == null) throw new IOError.INVALID_DATA ("not a task");
            TaskList? list = null;
            foreach (var l in app.store.lists) {
                if (!l.online && !links.has_key (l.id)) {
                    list = l;
                    break;
                }
            }
            if (list == null) list = app.store.add_list (_("Inbox"));
            var t = app.store.add_task (list.id, o.get_string_member_with_default ("title", ""));
            string uid = t.uid;
            apply_json (t, o);
            t.parent_uid = "";
            t.completed = false;
            t.completed_at = null;
            app.store.notify_changed ();
            app.flush ();
            app.activate ();
            var w = app.get_active_window () as TasksWindow;
            if (w != null) {
                var task = app.store.find (uid);
                if (task != null) w.show_task (task);
            }
            status (_("Task received from %s").printf (from));
        }

        public void join_list (string session_id, string title, string snapshot, string from) {
            var list = app.store.add_list (title != "" ? title : _("Shared List"));
            var doc = new Singularity.Collab.Document ();
            doc.load (snapshot);
            var l = bind (list.id, doc, title);
            l.host = from;
            var values = doc.values ();
            var all = new Gee.HashMap<string, string?> ();
            foreach (var e in values.entries) all[e.key] = e.value;
            apply_units (list.id, all, from);
            l.binding.adopt_local ();
            l.session.join (session_id, from);
            queue_save ();
            app.flush ();
            app.activate ();
            status (_("You share %s with %s").printf (list.name, from));
        }

        public void restore () {
            if (!available () || !FileUtils.test (state_path, FileTest.EXISTS)) return;
            string text;
            try {
                FileUtils.get_contents (state_path, out text);
            } catch (Error e) {
                return;
            }
            var root = Singularity.Collab.Shared.decode (text);
            if (root == null || !root.has_member ("lists")) return;
            foreach (var node in root.get_array_member ("lists").get_elements ()) {
                var o = node.get_object ();
                string list_id = o.get_string_member_with_default ("list", "");
                string sid = o.get_string_member_with_default ("session", "");
                var list = app.store.list (list_id);
                if (list == null || sid == "") continue;
                var doc = new Singularity.Collab.Document ();
                doc.load (o.get_string_member_with_default ("doc", ""));
                var l = bind (list_id, doc, list.name);
                l.host = o.get_string_member_with_default ("host", "");
                bool as_host = o.get_boolean_member_with_default ("hosting", false);
                l.session.resume.begin (sid, as_host, l.host, (obj, res) => {
                    if (!l.session.resume.end (res)) {
                        links.unset (list_id);
                        queue_save ();
                        return;
                    }
                    l.binding.local_changed ();
                });
            }
        }

        private void queue_save () {
            if (save_id != 0) return;
            save_id = Timeout.add (500, () => {
                save_id = 0;
                save_now ();
                return Source.REMOVE;
            });
        }

        public void save_now () {
            var arr = new Json.Array ();
            foreach (var l in links.values) {
                if (!l.session.active) continue;
                var o = new Json.Object ();
                o.set_string_member ("list", l.list_id);
                o.set_string_member ("session", l.session.id);
                o.set_boolean_member ("hosting", l.session.hosting);
                o.set_string_member ("host", l.host);
                o.set_string_member ("doc", l.doc.snapshot ());
                arr.add_object_element (o);
            }
            var root = new Json.Object ();
            root.set_array_member ("lists", arr);
            try {
                DirUtils.create_with_parents (Path.get_dirname (state_path), 0700);
                FileUtils.set_contents (state_path, Singularity.Collab.Shared.encode (root));
                FileUtils.chmod (state_path, 0600);
            } catch (Error e) {
                warning ("tasks: %s", e.message);
            }
        }
    }
}
