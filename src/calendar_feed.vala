namespace Singularity.Apps.Tasks {

    public class CalendarFeed : Object {
        public const string FILE_NAME = "dev.sinty.tasks.json";
        public const string CALENDAR_ID = "local-dev.sinty.tasks";
        public const string COLOR = "#8f9ba8";
        public const int TIMED_MINUTES = 30;

        public static string calendar_dir () {
            return Path.build_filename (Environment.get_user_data_dir (), "singularity", "calendar");
        }

        public static Gee.List<Task> due_tasks (TaskStore store) {
            var result = new Gee.ArrayList<Task> ();
            foreach (var t in store.tasks) {
                if (t.trashed || t.completed || t.due == null || store.list (t.list_id) == null) continue;
                result.add (t);
            }
            result.sort ((a, b) => {
                int c = a.due.compare (b.due);
                return c != 0 ? c : strcmp (a.uid, b.uid);
            });
            return result;
        }

        public static string build (TaskStore store) {
            var b = new Json.Builder ();
            b.begin_array ();
            foreach (var t in due_tasks (store)) {
                var start = t.due.to_local ();
                DateTime end;
                if (!t.due_has_time) {
                    start = new DateTime.local (start.get_year (), start.get_month (), start.get_day_of_month (), 0, 0, 0);
                    end = start.add_days (1);
                } else {
                    end = start.add_minutes (TIMED_MINUTES);
                }
                var list = store.list (t.list_id);
                string about = list != null ? _("Due in the %s list of Tasks").printf (list.name) : "";
                if (t.notes.strip () != "") about = about != "" ? about + "\n\n" + t.notes.strip () : t.notes.strip ();
                b.begin_object ();
                b.set_member_name ("id");
                b.add_string_value ("task-" + t.uid);
                b.set_member_name ("title");
                b.add_string_value (t.title != "" ? t.title : _("Untitled Task"));
                b.set_member_name ("description");
                b.add_string_value (about);
                b.set_member_name ("color");
                b.add_string_value ("");
                b.set_member_name ("all_day");
                b.add_boolean_value (!t.due_has_time);
                b.set_member_name ("start_time");
                b.add_string_value (start.format_iso8601 ());
                b.set_member_name ("end_time");
                b.add_string_value (end.format_iso8601 ());
                b.end_object ();
            }
            b.end_array ();
            var g = new Json.Generator ();
            g.pretty = true;
            g.set_root (b.get_root ());
            return g.to_data (null);
        }

        public static bool write (TaskStore store, string dir, bool enabled) throws Error {
            string path = Path.build_filename (dir, FILE_NAME);
            if (!enabled) {
                if (FileUtils.test (path, FileTest.EXISTS)) FileUtils.remove (path);
                return true;
            }
            string data = build (store);
            string old;
            try {
                FileUtils.get_contents (path, out old);
                if (old == data) return false;
            } catch (FileError e) {
            }
            DirUtils.create_with_parents (dir, 0755);
            register (dir);
            FileUtils.set_contents_full (path, data, -1, FileSetContentsFlags.CONSISTENT, 0644);
            return true;
        }

        private static void register (string dir) {
            string meta = Path.build_filename (dir, "calendars.ini");
            var kf = new KeyFile ();
            try {
                kf.load_from_file (meta, KeyFileFlags.KEEP_COMMENTS);
            } catch (Error e) {
            }
            if (kf.has_group (CALENDAR_ID)) return;
            kf.set_string (CALENDAR_ID, "name", _("Tasks"));
            kf.set_string (CALENDAR_ID, "color", COLOR);
            kf.set_boolean (CALENDAR_ID, "visible", true);
            try {
                kf.save_to_file (meta);
            } catch (Error e) {
                warning ("tasks: %s", e.message);
            }
        }
    }
}
