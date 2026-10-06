namespace Singularity.Apps.Tasks {

    public enum RepeatFrequency {
        NONE,
        DAILY,
        WEEKLY,
        MONTHLY,
        YEARLY;

        public string to_rrule () {
            switch (this) {
                case DAILY: return "DAILY";
                case WEEKLY: return "WEEKLY";
                case MONTHLY: return "MONTHLY";
                case YEARLY: return "YEARLY";
                default: return "";
            }
        }

        public static RepeatFrequency parse (string text) {
            switch (text.up ()) {
                case "DAILY": return DAILY;
                case "WEEKLY": return WEEKLY;
                case "MONTHLY": return MONTHLY;
                case "YEARLY": return YEARLY;
                default: return NONE;
            }
        }
    }

    public class RepeatRule : Object {
        public const string[] DAY_CODES = { "MO", "TU", "WE", "TH", "FR", "SA", "SU" };

        public RepeatFrequency frequency = RepeatFrequency.NONE;
        public int interval = 1;
        public Gee.ArrayList<int> days = new Gee.ArrayList<int> ();
        public int count = -1;
        public string until = "";
        public Gee.ArrayList<string> other = new Gee.ArrayList<string> ();

        public static RepeatRule? parse (string text) {
            string t = text.strip ();
            if (t.up ().has_prefix ("RRULE:")) t = t.substring (6);
            if (t == "") return null;
            var r = new RepeatRule ();
            foreach (string part in t.split (";")) {
                if (part == "") continue;
                int eq = part.index_of_char ('=');
                if (eq <= 0) return null;
                string key = part.substring (0, eq).up ();
                string value = part.substring (eq + 1);
                switch (key) {
                    case "FREQ":
                        r.frequency = RepeatFrequency.parse (value);
                        if (r.frequency == RepeatFrequency.NONE) return null;
                        break;
                    case "INTERVAL":
                        r.interval = int.parse (value);
                        if (r.interval < 1) return null;
                        break;
                    case "COUNT":
                        r.count = int.parse (value);
                        if (r.count < 1) return null;
                        break;
                    case "UNTIL":
                        r.until = value;
                        break;
                    case "BYDAY":
                        bool plain = true;
                        var parsed = new Gee.ArrayList<int> ();
                        foreach (string code in value.split (",")) {
                            int idx = -1;
                            for (int i = 0; i < DAY_CODES.length; i++) if (DAY_CODES[i] == code.up ()) idx = i;
                            if (idx < 0) plain = false;
                            else if (!parsed.contains (idx + 1)) parsed.add (idx + 1);
                        }
                        if (plain && parsed.size > 0) {
                            parsed.sort ((a, b) => a - b);
                            r.days = parsed;
                        } else {
                            r.other.add (part);
                        }
                        break;
                    default:
                        r.other.add (part);
                        break;
                }
            }
            if (r.frequency == RepeatFrequency.NONE) return null;
            return r;
        }

        public string to_string () {
            if (frequency == RepeatFrequency.NONE) return "";
            var sb = new StringBuilder ("FREQ=" + frequency.to_rrule ());
            if (interval > 1) sb.append (";INTERVAL=%d".printf (interval));
            if (days.size > 0) {
                string[] codes = {};
                foreach (int d in days) codes += DAY_CODES[d - 1];
                sb.append (";BYDAY=" + string.joinv (",", codes));
            }
            foreach (string o in other) sb.append (";" + o);
            if (count > 0) sb.append (";COUNT=%d".printf (count));
            if (until != "") sb.append (";UNTIL=" + until);
            return sb.str;
        }

        public bool is_weekdays () {
            return frequency == RepeatFrequency.WEEKLY && interval == 1 && days.size == 5 && days[0] == 1 && days[4] == 5;
        }

        public DateTime? until_time () {
            if (until.length < 8) return null;
            var p = new ICalProperty ();
            p.value = until;
            bool with_time;
            var d = ICal.parse_datetime (p, out with_time);
            if (d == null) return null;
            if (!with_time) d = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), 23, 59, 59);
            return d;
        }

        public DateTime? next_after (DateTime due) {
            if (count == 1) return null;
            var d = due.to_local ();
            DateTime next;
            switch (frequency) {
                case RepeatFrequency.DAILY:
                    next = d.add_days (interval);
                    break;
                case RepeatFrequency.WEEKLY:
                    if (days.size == 0) {
                        next = d.add_weeks (interval);
                        break;
                    }
                    int dow = d.get_day_of_week ();
                    int later = 0;
                    foreach (int day in days) {
                        if (day > dow) {
                            later = day;
                            break;
                        }
                    }
                    if (later > 0) next = d.add_days (later - dow);
                    else next = d.add_days (1 - dow).add_weeks (interval).add_days (days[0] - 1);
                    break;
                case RepeatFrequency.MONTHLY:
                    next = d.add_months (interval);
                    break;
                case RepeatFrequency.YEARLY:
                    next = d.add_years (interval);
                    break;
                default:
                    return null;
            }
            var limit = until_time ();
            if (limit != null && next.compare (limit) > 0) return null;
            return next;
        }

        public RepeatRule advanced () {
            var r = parse (to_string ()) ?? new RepeatRule ();
            if (r.count > 1) r.count--;
            return r;
        }

        private string day_names () {
            string[] names = {};
            foreach (int d in days) names += day_name (d);
            if (names.length == 1) return names[0];
            string head = string.joinv (", ", names[0:names.length - 1]);
            return _("%s and %s").printf (head, names[names.length - 1]);
        }

        public static string day_name (int d) {
            var base_day = new DateTime.local (2024, 1, 1, 12, 0, 0);
            return base_day.add_days (d - 1).format ("%A");
        }

        public string describe () {
            string s;
            if (is_weekdays ()) {
                s = _("Every weekday");
            } else {
                switch (frequency) {
                    case RepeatFrequency.DAILY:
                        s = interval == 1 ? _("Every day") : ngettext ("Every %d day", "Every %d days", interval).printf (interval);
                        break;
                    case RepeatFrequency.WEEKLY:
                        s = interval == 1 ? _("Every week") : ngettext ("Every %d week", "Every %d weeks", interval).printf (interval);
                        if (days.size > 0) s = _("%s on %s").printf (s, day_names ());
                        break;
                    case RepeatFrequency.MONTHLY:
                        s = interval == 1 ? _("Every month") : ngettext ("Every %d month", "Every %d months", interval).printf (interval);
                        break;
                    case RepeatFrequency.YEARLY:
                        s = interval == 1 ? _("Every year") : ngettext ("Every %d year", "Every %d years", interval).printf (interval);
                        break;
                    default:
                        return "";
                }
            }
            if (count > 0) s = _("%s, %s").printf (s, ngettext ("%d time left", "%d times left", count).printf (count));
            var limit = until_time ();
            if (limit != null) s = _("%s, until %s").printf (s, limit.format ("%-d %b %Y"));
            return s;
        }

        public static string describe_text (string rrule) {
            var r = parse (rrule);
            return r != null ? r.describe () : rrule;
        }
    }
}
