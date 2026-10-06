namespace Singularity.Apps.Tasks {

    public class Storage : Object {
        public const int VERSION = 1;
        public string path { get; construct; }

        public Storage (string path) {
            Object (path: path);
        }

        public static string default_path () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity", "tasks", "tasks.json");
        }

        public static string format_date (DateTime d, bool with_time) {
            if (!with_time) return d.to_local ().format ("%Y-%m-%d");
            return d.format_iso8601 ();
        }

        public static DateTime? parse_date (string? text, out bool with_time) {
            with_time = false;
            if (text == null || text == "") return null;
            if (text.length == 10) {
                int y = 0, m = 0, d = 0;
                if (text.scanf ("%d-%d-%d", out y, out m, out d) != 3) return null;
                if (m < 1 || m > 12 || d < 1 || d > 31) return null;
                return new DateTime.local (y, m, d, 0, 0, 0);
            }
            var dt = new DateTime.from_iso8601 (text, new TimeZone.local ());
            if (dt != null) with_time = true;
            return dt;
        }

        private static DateTime? parse_time (Json.Object o, string member) {
            if (!o.has_member (member)) return null;
            bool unused;
            var dt = parse_date (o.get_string_member (member), out unused);
            return dt;
        }

        public static string serialize (TaskStore store) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("version");
            b.add_int_value (VERSION);
            b.set_member_name ("lists");
            b.begin_array ();
            foreach (var l in store.lists) {
                if (l.online) continue;
                b.begin_object ();
                b.set_member_name ("id");
                b.add_string_value (l.id);
                b.set_member_name ("name");
                b.add_string_value (l.name);
                b.end_object ();
            }
            b.end_array ();
            b.set_member_name ("tasks");
            b.begin_array ();
            foreach (var t in store.tasks) {
                if (store.is_online (t)) continue;
                b.begin_object ();
                string_member (b, "uid", t.uid);
                string_member (b, "list", t.list_id);
                if (t.parent_uid != "") string_member (b, "parent", t.parent_uid);
                string_member (b, "title", t.title);
                if (t.notes != "") string_member (b, "notes", t.notes);
                if (t.due != null) string_member (b, "due", format_date (t.due, t.due_has_time));
                if (t.priority != Priority.NONE) {
                    b.set_member_name ("priority");
                    b.add_int_value ((int) t.priority);
                }
                if (t.tags.size > 0) {
                    b.set_member_name ("tags");
                    b.begin_array ();
                    foreach (string tag in t.tags) b.add_string_value (tag);
                    b.end_array ();
                }
                b.set_member_name ("completed");
                b.add_boolean_value (t.completed);
                if (t.completed_at != null) string_member (b, "completed_at", t.completed_at.format_iso8601 ());
                string_member (b, "created", t.created.format_iso8601 ());
                string_member (b, "modified", t.modified.format_iso8601 ());
                b.set_member_name ("position");
                b.add_int_value (t.position);
                if (t.trashed_at != null) string_member (b, "trashed_at", t.trashed_at.format_iso8601 ());
                if (t.reminder_minutes >= 0) {
                    b.set_member_name ("reminder_minutes");
                    b.add_int_value (t.reminder_minutes);
                }
                if (t.reminder_at != null) string_member (b, "reminder_at", t.reminder_at.format_iso8601 ());
                if (t.reminded > 0) {
                    b.set_member_name ("reminded");
                    b.add_int_value (t.reminded);
                }
                if (t.rrule != "") string_member (b, "rrule", t.rrule);
                if (t.focus_seconds > 0) {
                    b.set_member_name ("focus_seconds");
                    b.add_int_value (t.focus_seconds);
                }
                if (t.extra.size > 0) {
                    b.set_member_name ("ical_extra");
                    b.begin_array ();
                    foreach (string line in t.extra) b.add_string_value (line);
                    b.end_array ();
                }
                if (!t.expanded) {
                    b.set_member_name ("expanded");
                    b.add_boolean_value (false);
                }
                b.end_object ();
            }
            b.end_array ();
            b.end_object ();
            var g = new Json.Generator ();
            g.pretty = true;
            g.indent = 1;
            g.set_root (b.get_root ());
            return g.to_data (null);
        }

        private static void string_member (Json.Builder b, string name, string value) {
            b.set_member_name (name);
            b.add_string_value (value);
        }

        public static void deserialize (string data, TaskStore store) throws Error {
            var parser = new Json.Parser ();
            parser.load_from_data (data);
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("The task file is damaged."));
            var o = root.get_object ();
            store.lists.clear ();
            store.tasks.clear ();
            if (o.has_member ("lists")) {
                foreach (var node in o.get_array_member ("lists").get_elements ()) {
                    var lo = node.get_object ();
                    if (lo == null || !lo.has_member ("id")) continue;
                    store.lists.add (new TaskList (lo.get_string_member ("id"), lo.get_string_member_with_default ("name", _("Tasks"))));
                }
            }
            if (!o.has_member ("tasks")) return;
            foreach (var node in o.get_array_member ("tasks").get_elements ()) {
                var to = node.get_object ();
                if (to == null || !to.has_member ("uid")) continue;
                var t = new Task (to.get_string_member ("uid"));
                t.list_id = to.get_string_member_with_default ("list", "");
                t.parent_uid = to.get_string_member_with_default ("parent", "");
                t.title = to.get_string_member_with_default ("title", "");
                t.notes = to.get_string_member_with_default ("notes", "");
                bool with_time;
                t.due = parse_date (to.get_string_member_with_default ("due", ""), out with_time);
                t.due_has_time = with_time;
                t.priority = (Priority) ((int) to.get_int_member_with_default ("priority", 0)).clamp (0, 3);
                if (to.has_member ("tags")) {
                    foreach (var tag in to.get_array_member ("tags").get_elements ()) t.tags.add (tag.get_string ());
                }
                t.completed = to.get_boolean_member_with_default ("completed", false);
                t.completed_at = parse_time (to, "completed_at");
                t.created = parse_time (to, "created") ?? new DateTime.now_utc ();
                t.modified = parse_time (to, "modified") ?? t.created;
                t.position = (int) to.get_int_member_with_default ("position", 0);
                t.trashed_at = parse_time (to, "trashed_at");
                t.reminder_minutes = (int) to.get_int_member_with_default ("reminder_minutes", -1);
                t.reminder_at = parse_time (to, "reminder_at");
                t.reminded = to.get_int_member_with_default ("reminded", 0);
                t.rrule = to.get_string_member_with_default ("rrule", "");
                t.focus_seconds = to.get_int_member_with_default ("focus_seconds", 0);
                if (to.has_member ("ical_extra")) {
                    foreach (var line in to.get_array_member ("ical_extra").get_elements ()) t.extra.add (line.get_string ());
                }
                t.expanded = to.get_boolean_member_with_default ("expanded", true);
                store.tasks.add (t);
            }
        }

        public bool load (TaskStore store) throws Error {
            string data;
            try {
                FileUtils.get_contents (path, out data);
            } catch (FileError e) {
                if (e is FileError.NOENT) return false;
                throw e;
            }
            try {
                deserialize (data, store);
            } catch (Error e) {
                string aside = "%s.broken-%s".printf (path, new DateTime.now_local ().format ("%Y%m%d-%H%M%S"));
                FileUtils.rename (path, aside);
                store.lists.clear ();
                store.tasks.clear ();
                throw new IOError.INVALID_DATA (_("The saved tasks could not be read and were set aside as %s."), Path.get_basename (aside));
            }
            return true;
        }

        public void save (TaskStore store) throws Error {
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            FileUtils.set_contents_full (path, serialize (store), -1, FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
        }
    }
}
