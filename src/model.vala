namespace Singularity.Apps.Tasks {

    public enum Priority {
        NONE = 0,
        LOW = 1,
        MEDIUM = 2,
        HIGH = 3;

        public string label () {
            switch (this) {
                case LOW: return _("Low");
                case MEDIUM: return _("Medium");
                case HIGH: return _("High");
                default: return _("None");
            }
        }
    }

    public class TaskList : Object {
        public string id;
        public string name;
        public string account_id = "";
        public string account_name = "";
        public string icon_name = "view-list-symbolic";
        public string status = "";
        public bool read_only = false;
        public bool offline = false;
        public bool attention = false;

        public TaskList (string id, string name) {
            this.id = id;
            this.name = name;
        }

        public bool online {
            get { return account_id != ""; }
        }

        public string label () {
            return online ? _("%s (%s)").printf (name, account_name) : name;
        }
    }

    public class Task : Object {
        public string uid;
        public string list_id = "";
        public string parent_uid = "";
        public string title = "";
        public string notes = "";
        public DateTime? due = null;
        public bool due_has_time = false;
        public Priority priority = Priority.NONE;
        public Gee.ArrayList<string> tags = new Gee.ArrayList<string> ();
        public bool completed = false;
        public DateTime? completed_at = null;
        public DateTime created;
        public DateTime modified;
        public int position = 0;
        public DateTime? trashed_at = null;
        public int reminder_minutes = -1;
        public DateTime? reminder_at = null;
        public int64 reminded = 0;
        public string rrule = "";
        public int64 focus_seconds = 0;
        public Gee.ArrayList<string> extra = new Gee.ArrayList<string> ();
        public bool expanded = true;

        public const int ALL_DAY_REMINDER_HOUR = 9;

        public Task (string? uid = null) {
            this.uid = uid ?? Uuid.string_random ();
            created = new DateTime.now_utc ();
            modified = created;
        }

        public bool trashed {
            get { return trashed_at != null; }
        }

        public DateTime? reminder_time () {
            if (reminder_at != null) return reminder_at;
            if (reminder_minutes < 0 || due == null) return null;
            DateTime base_time = due;
            if (!due_has_time) {
                var d = due.to_local ();
                base_time = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), ALL_DAY_REMINDER_HOUR, 0, 0);
            }
            return base_time.add_minutes (-reminder_minutes);
        }

        public bool matches (string query) {
            string q = query.strip ().casefold ();
            if (q == "") return true;
            foreach (string word in q.split (" ")) {
                if (word == "") continue;
                bool hit = false;
                if (word.has_prefix ("#") && word.length > 1) {
                    string tag = word.substring (1);
                    foreach (string t in tags) if (t.casefold () == tag) hit = true;
                } else {
                    if (title.casefold ().contains (word) || notes.casefold ().contains (word)) hit = true;
                    foreach (string t in tags) if (t.casefold ().contains (word)) hit = true;
                }
                if (!hit) return false;
            }
            return true;
        }

        public void set_tags_from_text (string text) {
            tags.clear ();
            foreach (string part in text.split (",")) {
                string t = part.strip ();
                if (t.has_prefix ("#")) t = t.substring (1).strip ();
                if (t == "") continue;
                bool dup = false;
                foreach (string e in tags) if (e.casefold () == t.casefold ()) dup = true;
                if (!dup) tags.add (t);
            }
        }

        public string tags_text () {
            return string.joinv (", ", tags.to_array ());
        }
    }

    public class TaskStore : Object {
        public Gee.ArrayList<TaskList> lists = new Gee.ArrayList<TaskList> ();
        public Gee.ArrayList<Task> tasks = new Gee.ArrayList<Task> ();

        public signal void changed ();

        public static int date_key (DateTime d) {
            var l = d.to_local ();
            return l.get_year () * 10000 + l.get_month () * 100 + l.get_day_of_month ();
        }

        public void notify_changed () {
            changed ();
        }

        public TaskList? list (string id) {
            foreach (var l in lists) if (l.id == id) return l;
            return null;
        }

        public bool is_online (Task t) {
            var l = list (t.list_id);
            return l != null && l.online;
        }

        public bool is_read_only (Task t) {
            var l = list (t.list_id);
            return l != null && l.read_only;
        }

        public TaskList? list_by_name (string name) {
            foreach (var l in lists) if (!l.online && l.name.casefold () == name.casefold ()) return l;
            return null;
        }

        public TaskList add_list (string name) {
            var l = new TaskList (Uuid.string_random (), name.strip () != "" ? name.strip () : _("Tasks"));
            lists.add (l);
            return l;
        }

        public TaskList ensure_list () {
            foreach (var l in lists) if (!l.online) return l;
            foreach (var l in lists) if (!l.read_only) return l;
            return add_list (_("Tasks"));
        }

        public void remove_list (TaskList l, DateTime now) {
            foreach (var t in tasks) {
                if (t.list_id == l.id && !t.trashed) t.trashed_at = now;
            }
            lists.remove (l);
        }

        public Task? find (string uid) {
            foreach (var t in tasks) if (t.uid == uid) return t;
            return null;
        }

        public Task? parent_of (Task t) {
            return t.parent_uid != "" ? find (t.parent_uid) : null;
        }

        public int depth (Task t) {
            int d = 0;
            var p = parent_of (t);
            while (p != null && d < 64) {
                d++;
                p = parent_of (p);
            }
            return d;
        }

        public Gee.List<Task> children (string list_id, string parent_uid, bool include_trashed = false) {
            var result = new Gee.ArrayList<Task> ();
            foreach (var t in tasks) {
                if (t.list_id != list_id || t.parent_uid != parent_uid) continue;
                if (t.trashed && !include_trashed) continue;
                result.add (t);
            }
            result.sort ((a, b) => a.position - b.position);
            return result;
        }

        public Gee.List<Task> descendants (Task root, bool include_trashed = false) {
            var result = new Gee.ArrayList<Task> ();
            collect (root, result, include_trashed);
            return result;
        }

        private void collect (Task parent, Gee.ArrayList<Task> into, bool include_trashed) {
            foreach (var c in children (parent.list_id, parent.uid, include_trashed)) {
                if (into.contains (c)) continue;
                into.add (c);
                collect (c, into, include_trashed);
            }
        }

        public bool has_children (Task t) {
            foreach (var c in tasks) if (c.parent_uid == t.uid && c.list_id == t.list_id && !c.trashed) return true;
            return false;
        }

        public void progress (Task t, out int done, out int total) {
            done = 0;
            total = 0;
            foreach (var d in descendants (t)) {
                total++;
                if (d.completed) done++;
            }
        }

        public Task add_task (string list_id, string title, string parent_uid = "") {
            var t = new Task ();
            t.list_id = list_id;
            t.parent_uid = parent_uid;
            t.title = title.strip ();
            var siblings = children (list_id, parent_uid);
            t.position = siblings.size > 0 ? siblings[siblings.size - 1].position + 1 : 0;
            tasks.add (t);
            return t;
        }

        public Task? set_completed (Task t, bool done, DateTime now) {
            bool was_done = t.completed;
            apply_completed (t, done, now);
            Task? next = null;
            if (done && !was_done) next = repeat (t);
            if (done) {
                foreach (var d in descendants (t)) apply_completed (d, true, now);
            } else {
                var p = parent_of (t);
                while (p != null) {
                    apply_completed (p, false, now);
                    p = parent_of (p);
                }
            }
            return next;
        }

        public Task? repeat (Task t) {
            if (t.rrule == "" || t.due == null || t.trashed) return null;
            var rule = RepeatRule.parse (t.rrule);
            if (rule == null) return null;
            var when = rule.next_after (t.due);
            t.rrule = "";
            if (when == null) return null;
            var next = copy_task (t, t.list_id, t.parent_uid);
            next.due = when;
            next.due_has_time = t.due_has_time;
            next.rrule = rule.advanced ().to_string ();
            if (t.reminder_at != null) next.reminder_at = t.reminder_at.add (when.difference (t.due));
            var siblings = children (t.list_id, t.parent_uid);
            int index = siblings.index_of (t);
            foreach (var s in siblings) if (s != next && s.position > t.position) s.position++;
            next.position = t.position + 1;
            if (index < 0) next.position = siblings.size;
            foreach (var c in children (t.list_id, t.uid)) clone_subtree (c, next.uid);
            return next;
        }

        private Task copy_task (Task source, string list_id, string parent_uid) {
            var n = new Task ();
            n.list_id = list_id;
            n.parent_uid = parent_uid;
            n.title = source.title;
            n.notes = source.notes;
            n.priority = source.priority;
            n.tags.add_all (source.tags);
            n.reminder_minutes = source.reminder_minutes;
            n.due = source.due;
            n.due_has_time = source.due_has_time;
            n.expanded = source.expanded;
            n.position = source.position;
            tasks.add (n);
            return n;
        }

        private void clone_subtree (Task source, string parent_uid) {
            var n = copy_task (source, source.list_id, parent_uid);
            n.due = null;
            n.due_has_time = false;
            n.reminder_minutes = -1;
            foreach (var c in children (source.list_id, source.uid)) clone_subtree (c, n.uid);
        }

        private static void apply_completed (Task t, bool done, DateTime now) {
            if (t.completed == done) return;
            t.completed = done;
            t.completed_at = done ? now : null;
            t.modified = now;
        }

        public bool is_ancestor (Task maybe_ancestor, Task t) {
            var p = parent_of (t);
            int guard = 0;
            while (p != null && guard++ < 64) {
                if (p == maybe_ancestor) return true;
                p = parent_of (p);
            }
            return false;
        }

        public bool move (Task t, string list_id, string parent_uid, int index) {
            if (parent_uid == t.uid) return false;
            var new_parent = parent_uid != "" ? find (parent_uid) : null;
            if (parent_uid != "" && (new_parent == null || new_parent == t || is_ancestor (t, new_parent))) return false;
            var subtree = descendants (t, true);
            var siblings = children (list_id, parent_uid);
            siblings.remove (t);
            index = index.clamp (0, siblings.size);
            siblings.insert (index, t);
            t.list_id = list_id;
            t.parent_uid = parent_uid;
            foreach (var d in subtree) d.list_id = list_id;
            for (int i = 0; i < siblings.size; i++) siblings[i].position = i;
            t.modified = new DateTime.now_utc ();
            return true;
        }

        public bool move_next_to (Task t, Task target, bool after) {
            if (t == target || is_ancestor (t, target)) return false;
            var siblings = children (target.list_id, target.parent_uid);
            siblings.remove (t);
            int index = siblings.index_of (target);
            if (index < 0) index = siblings.size;
            return move (t, target.list_id, target.parent_uid, after ? index + 1 : index);
        }

        public bool move_to_list (Task t, string list_id) {
            if (list (list_id) == null) return false;
            if (t.list_id == list_id && t.parent_uid == "") return false;
            return move (t, list_id, "", int.MAX);
        }

        public void trash (Task t, DateTime now) {
            t.trashed_at = now;
            foreach (var d in descendants (t)) d.trashed_at = now;
        }

        public void restore (Task t) {
            var stamp = t.trashed_at;
            var subtree = descendants (t, true);
            t.trashed_at = null;
            foreach (var d in subtree) if (d.trashed_at != null && stamp != null && d.trashed_at.equal (stamp)) d.trashed_at = null;
            var p = parent_of (t);
            if (t.parent_uid != "" && (p == null || p.trashed)) t.parent_uid = "";
            if (list (t.list_id) == null) {
                string target = ensure_list ().id;
                t.list_id = target;
                t.parent_uid = "";
                foreach (var d in subtree) d.list_id = target;
            }
            var siblings = children (t.list_id, t.parent_uid);
            siblings.remove (t);
            t.position = siblings.size > 0 ? siblings[siblings.size - 1].position + 1 : 0;
        }

        public void purge (Task t) {
            var subtree = descendants (t, true);
            tasks.remove (t);
            foreach (var d in subtree) tasks.remove (d);
        }

        public Gee.List<Task> trashed_roots () {
            var result = new Gee.ArrayList<Task> ();
            foreach (var t in tasks) {
                if (!t.trashed) continue;
                var p = parent_of (t);
                if (p != null && p.trashed) continue;
                result.add (t);
            }
            result.sort ((a, b) => b.trashed_at.compare (a.trashed_at));
            return result;
        }

        public void empty_trash () {
            var keep = new Gee.ArrayList<Task> ();
            foreach (var t in tasks) if (!t.trashed) keep.add (t);
            tasks = keep;
        }

        private bool live (Task t) {
            return !t.trashed && list (t.list_id) != null;
        }

        private static int by_due (Task a, Task b) {
            int c = a.due.compare (b.due);
            if (c != 0) return c;
            if (a.priority != b.priority) return (int) b.priority - (int) a.priority;
            return a.position - b.position;
        }

        public Gee.List<Task> today (DateTime now) {
            int key = date_key (now);
            var result = new Gee.ArrayList<Task> ();
            foreach (var t in tasks) {
                if (!live (t) || t.completed || t.due == null) continue;
                if (date_key (t.due) <= key) result.add (t);
            }
            result.sort (by_due);
            return result;
        }

        public Gee.List<Task> upcoming (DateTime now) {
            int key = date_key (now);
            var result = new Gee.ArrayList<Task> ();
            foreach (var t in tasks) {
                if (!live (t) || t.completed || t.due == null) continue;
                if (date_key (t.due) > key) result.add (t);
            }
            result.sort (by_due);
            return result;
        }

        public Gee.List<Task> search (string query) {
            var result = new Gee.ArrayList<Task> ();
            foreach (var t in tasks) {
                if (live (t) && t.matches (query)) result.add (t);
            }
            result.sort ((a, b) => {
                if (a.completed != b.completed) return a.completed ? 1 : -1;
                return strcmp (a.title.casefold (), b.title.casefold ());
            });
            return result;
        }

        public int count_open (string list_id) {
            int n = 0;
            foreach (var t in tasks) if (t.list_id == list_id && !t.trashed && !t.completed) n++;
            return n;
        }

        public int count_trashed () {
            int n = 0;
            foreach (var t in tasks) if (t.trashed) n++;
            return n;
        }

        public Gee.List<Task> completed_in (string list_id) {
            var result = new Gee.ArrayList<Task> ();
            foreach (var t in tasks) {
                if (t.list_id != list_id || t.trashed || !t.completed) continue;
                var p = parent_of (t);
                if (p != null && p.completed) continue;
                result.add (t);
            }
            return result;
        }

        public Gee.List<Task> due_reminders (DateTime now) {
            var result = new Gee.ArrayList<Task> ();
            int64 now_unix = now.to_unix ();
            foreach (var t in tasks) {
                if (!live (t) || t.completed) continue;
                var at = t.reminder_time ();
                if (at == null) continue;
                int64 when = at.to_unix ();
                if (when > now_unix || t.reminded >= when) continue;
                if (now_unix - when > 86400) continue;
                result.add (t);
            }
            return result;
        }

        public DateTime? next_reminder (DateTime now) {
            DateTime? best = null;
            int64 now_unix = now.to_unix ();
            foreach (var t in tasks) {
                if (!live (t) || t.completed) continue;
                var at = t.reminder_time ();
                if (at == null || at.to_unix () <= now_unix || t.reminded >= at.to_unix ()) continue;
                if (best == null || at.compare (best) < 0) best = at;
            }
            return best;
        }

        public Gee.List<Task> in_order (string list_id) {
            var result = new Gee.ArrayList<Task> ();
            foreach (var t in children (list_id, "")) {
                result.add (t);
                result.add_all (descendants (t));
            }
            return result;
        }
    }
}
