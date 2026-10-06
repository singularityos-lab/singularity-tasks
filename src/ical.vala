namespace Singularity.Apps.Tasks {

    public class ICalProperty : Object {
        public string name = "";
        public Gee.HashMap<string, string> params = new Gee.HashMap<string, string> ();
        public string value = "";
        public string raw = "";

        public string param (string key) {
            return params.has_key (key) ? params[key] : "";
        }
    }

    public class ImportedTask : Object {
        public Task task;
        public string list_name = "";

        public ImportedTask (Task task) {
            this.task = task;
        }
    }

    public class ICal : Object {
        public const string LIST_PROPERTY = "X-SINGULARITY-LIST";
        private const int FOLD_OCTETS = 75;

        public static string escape (string text) {
            var sb = new StringBuilder ();
            unichar c;
            int i = 0;
            while (text.get_next_char (ref i, out c)) {
                switch (c) {
                    case '\\': sb.append ("\\\\"); break;
                    case ';': sb.append ("\\;"); break;
                    case ',': sb.append ("\\,"); break;
                    case '\n': sb.append ("\\n"); break;
                    case '\r': break;
                    default: sb.append_unichar (c); break;
                }
            }
            return sb.str;
        }

        public static string unescape (string text) {
            var sb = new StringBuilder ();
            unichar c;
            int i = 0;
            bool slash = false;
            while (text.get_next_char (ref i, out c)) {
                if (slash) {
                    if (c == 'n' || c == 'N') sb.append_c ('\n');
                    else sb.append_unichar (c);
                    slash = false;
                } else if (c == '\\') {
                    slash = true;
                } else {
                    sb.append_unichar (c);
                }
            }
            if (slash) sb.append_c ('\\');
            return sb.str;
        }

        public static Gee.List<string> split_list (string value) {
            var result = new Gee.ArrayList<string> ();
            var sb = new StringBuilder ();
            bool slash = false;
            for (int i = 0; i < value.length; i++) {
                char c = value[i];
                if (slash) {
                    sb.append_c ('\\');
                    sb.append_c (c);
                    slash = false;
                } else if (c == '\\') {
                    slash = true;
                } else if (c == ',') {
                    result.add (unescape (sb.str));
                    sb.truncate ();
                } else {
                    sb.append_c (c);
                }
            }
            result.add (unescape (sb.str));
            return result;
        }

        public static string fold (string line) {
            if (line.length <= FOLD_OCTETS) return line + "\r\n";
            var sb = new StringBuilder ();
            int start = 0;
            int limit = FOLD_OCTETS;
            while (start < line.length) {
                int end = start + limit;
                if (end >= line.length) {
                    end = line.length;
                } else {
                    while (end > start && (((uint8) line[end]) & 0xC0) == 0x80) end--;
                }
                if (start > 0) sb.append_c (' ');
                sb.append (line.substring (start, end - start));
                sb.append ("\r\n");
                start = end;
                limit = FOLD_OCTETS - 1;
            }
            return sb.str;
        }

        public static Gee.List<string> unfold (string text) {
            var result = new Gee.ArrayList<string> ();
            foreach (string raw in text.replace ("\r\n", "\n").replace ("\r", "\n").split ("\n")) {
                if ((raw.has_prefix (" ") || raw.has_prefix ("\t")) && result.size > 0) {
                    result[result.size - 1] = result[result.size - 1] + raw.substring (1);
                } else if (raw != "") {
                    result.add (raw);
                }
            }
            return result;
        }

        public static ICalProperty parse_line (string line) {
            var p = new ICalProperty ();
            p.raw = line;
            bool quoted = false;
            int colon = -1;
            for (int i = 0; i < line.length; i++) {
                char c = line[i];
                if (c == '"') quoted = !quoted;
                else if (c == ':' && !quoted) {
                    colon = i;
                    break;
                }
            }
            string head = colon >= 0 ? line.substring (0, colon) : line;
            p.value = colon >= 0 ? line.substring (colon + 1) : "";
            var parts = new Gee.ArrayList<string> ();
            var sb = new StringBuilder ();
            quoted = false;
            for (int i = 0; i < head.length; i++) {
                char c = head[i];
                if (c == '"') quoted = !quoted;
                if (c == ';' && !quoted) {
                    parts.add (sb.str);
                    sb.truncate ();
                } else {
                    sb.append_c (c);
                }
            }
            parts.add (sb.str);
            p.name = parts[0].up ();
            for (int i = 1; i < parts.size; i++) {
                int eq = parts[i].index_of ("=");
                if (eq < 0) continue;
                string v = parts[i].substring (eq + 1);
                if (v.length >= 2 && v.has_prefix ("\"") && v.has_suffix ("\"")) v = v.substring (1, v.length - 2);
                p.params[parts[i].substring (0, eq).up ()] = v;
            }
            return p;
        }

        public static string format_utc (DateTime d) {
            return d.to_utc ().format ("%Y%m%dT%H%M%SZ");
        }

        public static DateTime? parse_datetime (ICalProperty p, out bool with_time) {
            with_time = false;
            string v = p.value.strip ();
            if (v.length < 8) return null;
            int y = int.parse (v.substring (0, 4)), m = int.parse (v.substring (4, 2)), d = int.parse (v.substring (6, 2));
            if (y < 1 || m < 1 || m > 12 || d < 1 || d > 31) return null;
            if (v.length == 8 || p.param ("VALUE").up () == "DATE") return new DateTime.local (y, m, d, 0, 0, 0);
            if (v.length < 15 || v[8] != 'T') return null;
            int hh = int.parse (v.substring (9, 2)), mm = int.parse (v.substring (11, 2)), ss = int.parse (v.substring (13, 2));
            with_time = true;
            if (v.has_suffix ("Z")) return new DateTime.utc (y, m, d, hh, mm, ss).to_local ();
            string tzid = p.param ("TZID");
            if (tzid != "") {
                TimeZone? tz = null;
                try {
                    tz = new TimeZone.identifier (tzid);
                } catch (Error e) {
                    tz = null;
                }
                if (tz != null) return new DateTime (tz, y, m, d, hh, mm, ss).to_local ();
            }
            return new DateTime.local (y, m, d, hh, mm, ss);
        }

        public static bool parse_duration (string text, out int64 seconds) {
            seconds = 0;
            string s = text.strip ().up ();
            int sign = 1;
            if (s.has_prefix ("-")) {
                sign = -1;
                s = s.substring (1);
            } else if (s.has_prefix ("+")) {
                s = s.substring (1);
            }
            if (!s.has_prefix ("P")) return false;
            bool in_time = false;
            int64 number = 0;
            bool have_number = false;
            for (int i = 1; i < s.length; i++) {
                char c = s[i];
                if (c.isdigit ()) {
                    number = number * 10 + (c - '0');
                    have_number = true;
                    continue;
                }
                if (c == 'T') {
                    in_time = true;
                    continue;
                }
                if (!have_number) return false;
                switch (c) {
                    case 'W': seconds += number * 604800; break;
                    case 'D': seconds += number * 86400; break;
                    case 'H': if (!in_time) return false; seconds += number * 3600; break;
                    case 'M': if (!in_time) return false; seconds += number * 60; break;
                    case 'S': if (!in_time) return false; seconds += number; break;
                    default: return false;
                }
                number = 0;
                have_number = false;
            }
            if (have_number) return false;
            seconds *= sign;
            return true;
        }

        public static string format_duration_before (int minutes) {
            if (minutes == 0) return "PT0S";
            if (minutes % 1440 == 0) return "-P%dD".printf (minutes / 1440);
            if (minutes % 60 == 0) return "-PT%dH".printf (minutes / 60);
            return "-PT%dM".printf (minutes);
        }

        public static Gee.List<ImportedTask> parse (string text, out string calendar_name) {
            calendar_name = "";
            var result = new Gee.ArrayList<ImportedTask> ();
            var stack = new Gee.ArrayList<string> ();
            ImportedTask? current = null;
            bool in_alarm = false;
            string alarm_trigger = "";
            ICalProperty? alarm_prop = null;
            bool have_percent_done = false;
            foreach (string line in unfold (text)) {
                var p = parse_line (line);
                if (p.name == "BEGIN") {
                    string comp = p.value.strip ().up ();
                    stack.add (comp);
                    if (comp == "VTODO" && current == null) {
                        current = new ImportedTask (new Task (""));
                        current.task.uid = "";
                        have_percent_done = false;
                    } else if (comp == "VALARM" && current != null) {
                        in_alarm = true;
                        alarm_trigger = "";
                        alarm_prop = null;
                    }
                    continue;
                }
                if (p.name == "END") {
                    string comp = p.value.strip ().up ();
                    if (stack.size > 0) stack.remove_at (stack.size - 1);
                    if (comp == "VALARM" && in_alarm) {
                        in_alarm = false;
                        if (alarm_prop != null && current.task.reminder_minutes < 0 && current.task.reminder_at == null) apply_trigger (current.task, alarm_prop);
                    } else if (comp == "VTODO" && current != null) {
                        if (current.task.uid == "") current.task.uid = Uuid.string_random ();
                        if (have_percent_done && !current.task.completed) {
                            current.task.completed = true;
                        }
                        result.add (current);
                        current = null;
                    }
                    continue;
                }
                if (current == null) {
                    if (p.name == "X-WR-CALNAME" && stack.size == 1) calendar_name = unescape (p.value).strip ();
                    continue;
                }
                if (in_alarm) {
                    if (p.name == "TRIGGER") alarm_prop = p;
                    continue;
                }
                if (stack.size == 0 || stack[stack.size - 1] != "VTODO") continue;
                var t = current.task;
                bool with_time;
                switch (p.name) {
                    case "UID": t.uid = p.value.strip (); break;
                    case "SUMMARY": t.title = unescape (p.value); break;
                    case "DESCRIPTION": t.notes = unescape (p.value); break;
                    case "DUE":
                        t.due = parse_datetime (p, out with_time);
                        t.due_has_time = with_time;
                        break;
                    case "PRIORITY":
                        int pr = int.parse (p.value.strip ());
                        t.priority = pr <= 0 ? Priority.NONE : (pr <= 4 ? Priority.HIGH : (pr == 5 ? Priority.MEDIUM : Priority.LOW));
                        break;
                    case "CATEGORIES":
                        foreach (string c in split_list (p.value)) {
                            string tag = c.strip ();
                            if (tag != "" && !t.tags.contains (tag)) t.tags.add (tag);
                        }
                        break;
                    case "STATUS":
                        t.completed = p.value.strip ().up () == "COMPLETED";
                        break;
                    case "COMPLETED":
                        t.completed_at = parse_datetime (p, out with_time);
                        break;
                    case "PERCENT-COMPLETE":
                        have_percent_done = int.parse (p.value.strip ()) >= 100;
                        break;
                    case "CREATED":
                        var c = parse_datetime (p, out with_time);
                        if (c != null) t.created = c;
                        break;
                    case "LAST-MODIFIED":
                        var m = parse_datetime (p, out with_time);
                        if (m != null) t.modified = m;
                        break;
                    case "DTSTAMP":
                        break;
                    case "RELATED-TO":
                        string rel = p.param ("RELTYPE").up ();
                        if (rel == "" || rel == "PARENT") t.parent_uid = p.value.strip ();
                        else t.extra.add (p.raw);
                        break;
                    case "RRULE":
                        t.rrule = p.value.strip ();
                        break;
                    case LIST_PROPERTY:
                        current.list_name = unescape (p.value).strip ();
                        break;
                    default:
                        t.extra.add (p.raw);
                        break;
                }
            }
            return result;
        }

        private static void apply_trigger (Task t, ICalProperty trigger) {
            string v = trigger.value.strip ();
            if (trigger.param ("VALUE").up () == "DATE-TIME" || (v.length >= 15 && v[8] == 'T' && v[0].isdigit ())) {
                bool with_time;
                t.reminder_at = parse_datetime (trigger, out with_time);
                return;
            }
            int64 seconds;
            if (!parse_duration (v, out seconds)) return;
            if (seconds <= 0) {
                t.reminder_minutes = (int) (-seconds / 60);
            } else if (t.due != null) {
                t.reminder_at = t.due.add_seconds (seconds);
            }
        }

        public static string export (Gee.List<Task> tasks, TaskStore store, string? calendar_name, DateTime now) {
            var sb = new StringBuilder ();
            sb.append ("BEGIN:VCALENDAR\r\n");
            sb.append ("VERSION:2.0\r\n");
            sb.append ("PRODID:-//Singularity//Tasks//EN\r\n");
            sb.append ("CALSCALE:GREGORIAN\r\n");
            if (calendar_name != null && calendar_name != "") sb.append (fold ("X-WR-CALNAME:" + escape (calendar_name)));
            foreach (var t in tasks) sb.append (export_task (t, store, now));
            sb.append ("END:VCALENDAR\r\n");
            return sb.str;
        }

        public static string export_task (Task t, TaskStore store, DateTime now) {
            var sb = new StringBuilder ();
            sb.append ("BEGIN:VTODO\r\n");
            sb.append (fold ("UID:" + t.uid));
            sb.append ("DTSTAMP:" + format_utc (now) + "\r\n");
            sb.append ("CREATED:" + format_utc (t.created) + "\r\n");
            sb.append ("LAST-MODIFIED:" + format_utc (t.modified) + "\r\n");
            sb.append (fold ("SUMMARY:" + escape (t.title)));
            if (t.notes != "") sb.append (fold ("DESCRIPTION:" + escape (t.notes)));
            if (t.due != null) {
                if (t.due_has_time) sb.append ("DUE:" + format_utc (t.due) + "\r\n");
                else sb.append ("DUE;VALUE=DATE:" + t.due.to_local ().format ("%Y%m%d") + "\r\n");
            }
            switch (t.priority) {
                case Priority.HIGH: sb.append ("PRIORITY:1\r\n"); break;
                case Priority.MEDIUM: sb.append ("PRIORITY:5\r\n"); break;
                case Priority.LOW: sb.append ("PRIORITY:9\r\n"); break;
                default: break;
            }
            if (t.tags.size > 0) {
                string[] escaped = {};
                foreach (string tag in t.tags) escaped += escape (tag);
                sb.append (fold ("CATEGORIES:" + string.joinv (",", escaped)));
            }
            if (t.completed) {
                sb.append ("STATUS:COMPLETED\r\n");
                sb.append ("PERCENT-COMPLETE:100\r\n");
                sb.append ("COMPLETED:" + format_utc (t.completed_at ?? t.modified) + "\r\n");
            } else {
                sb.append ("STATUS:NEEDS-ACTION\r\n");
            }
            if (t.parent_uid != "") sb.append (fold ("RELATED-TO;RELTYPE=PARENT:" + t.parent_uid));
            if (t.rrule != "") sb.append (fold ("RRULE:" + t.rrule));
            var list = store.list (t.list_id);
            if (list != null) sb.append (fold (LIST_PROPERTY + ":" + escape (list.name)));
            foreach (string line in t.extra) sb.append (fold (line));
            if (t.reminder_at != null || (t.reminder_minutes >= 0 && t.due != null)) {
                sb.append ("BEGIN:VALARM\r\n");
                sb.append ("ACTION:DISPLAY\r\n");
                sb.append (fold ("DESCRIPTION:" + escape (t.title)));
                if (t.reminder_at != null) sb.append ("TRIGGER;VALUE=DATE-TIME:" + format_utc (t.reminder_at) + "\r\n");
                else if (t.due_has_time) sb.append ("TRIGGER;RELATED=END:" + format_duration_before (t.reminder_minutes) + "\r\n");
                else sb.append ("TRIGGER;VALUE=DATE-TIME:" + format_utc (t.reminder_time ()) + "\r\n");
                sb.append ("END:VALARM\r\n");
            }
            sb.append ("END:VTODO\r\n");
            return sb.str;
        }

        public static int import_into (TaskStore store, Gee.List<ImportedTask> items, string calendar_name, string fallback_name) {
            var by_name = new Gee.HashMap<string, TaskList> ();
            int count = 0;
            var uids = new Gee.HashSet<string> ();
            foreach (var it in items) uids.add (it.task.uid);
            int next = 0;
            foreach (var t in store.tasks) next = int.max (next, t.position + 1);
            foreach (var it in items) {
                string name = it.list_name != "" ? it.list_name : (calendar_name != "" ? calendar_name : fallback_name);
                TaskList? list = by_name[name.casefold ()];
                if (list == null) {
                    list = store.list_by_name (name) ?? store.add_list (name);
                    by_name[name.casefold ()] = list;
                }
                var incoming = it.task;
                incoming.list_id = list.id;
                var existing = store.find (incoming.uid);
                if (existing != null) {
                    incoming.position = existing.position;
                    store.tasks.remove (existing);
                } else {
                    incoming.position = next++;
                }
                store.tasks.add (incoming);
                count++;
            }
            foreach (var it in items) {
                var t = it.task;
                if (t.parent_uid == "") continue;
                var parent = store.find (t.parent_uid);
                if (parent == null || parent == t || store.is_ancestor (t, parent) || (parent.list_id != t.list_id && !uids.contains (parent.uid))) {
                    t.parent_uid = "";
                } else if (parent.list_id != t.list_id) {
                    t.list_id = parent.list_id;
                }
            }
            return count;
        }
    }
}
