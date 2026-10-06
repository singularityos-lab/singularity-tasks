namespace Singularity.Apps.Tasks {

    public class QuickEntry : Object {
        public string title = "";
        public DateTime? due = null;
        public bool due_has_time = false;
        public string rrule = "";
        public Priority priority = Priority.NONE;
        public Gee.ArrayList<string> tags = new Gee.ArrayList<string> ();

        public bool understood () {
            return due != null || rrule != "" || priority != Priority.NONE || tags.size > 0;
        }
    }

    public class QuickParser : Object {
        private const string[] WEEKDAYS = { "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" };
        private const string[] WEEKDAYS_SHORT = { "mon", "tue", "wed", "thu", "fri", "sat", "sun" };
        private const string[] WEEKDAYS_IT = { "lunedi", "martedi", "mercoledi", "giovedi", "venerdi", "sabato", "domenica" };
        private const string[] MONTHS = { "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december" };
        private const string[] MONTHS_SHORT = { "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
        private const string[] MONTHS_IT = { "gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre" };
        private const string[] MONTHS_IT_SHORT = { "gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic" };
        private const string[] BYDAY = { "MO", "TU", "WE", "TH", "FR", "SA", "SU" };

        private string[] orig;
        private string[] norm;
        private bool[] used;
        private DateTime now;
        private int year = 0;
        private int month = 0;
        private int day = 0;
        private int hour = -1;
        private int minute = 0;
        private int weekday = 0;
        private bool weekday_today;
        private string rrule = "";
        private int rule_weekday = 0;
        private bool rule_weekdays;

        private QuickParser (string text, DateTime now) {
            this.now = now.to_local ();
            string[] o = {};
            string[] n = {};
            foreach (string w in text.strip ().split_set (" \t\n")) {
                if (w == "") continue;
                o += w;
                n += normalize (w);
            }
            orig = o;
            norm = n;
            used = new bool[o.length];
        }

        private bool dates = true;
        private bool repeats = true;
        private bool priorities = true;
        private Gee.Collection<string>? ignored_tags;

        public static QuickEntry parse (string text, DateTime now) {
            var p = new QuickParser (text, now);
            return p.run (text);
        }

        public static QuickEntry parse_with (string text, DateTime now, bool dates, bool repeats, bool priorities, Gee.Collection<string>? ignored_tags) {
            var p = new QuickParser (text, now);
            p.dates = dates;
            p.repeats = repeats;
            p.priorities = priorities;
            p.ignored_tags = ignored_tags;
            return p.run (text);
        }

        private static string normalize (string word) {
            string w = word.down ();
            while (w.length > 1 && (w.has_suffix (",") || w.has_suffix (".") || w.has_suffix (";") || w.has_suffix ("?"))) w = w.substring (0, w.length - 1);
            return w.replace ("ì", "i").replace ("è", "e").replace ("é", "e").replace ("à", "a").replace ("ò", "o").replace ("ù", "u");
        }

        private static string clean_tag (string word) {
            string t = word.substring (1);
            while (t.length > 0 && (t.has_suffix (",") || t.has_suffix (".") || t.has_suffix (";"))) t = t.substring (0, t.length - 1);
            return t;
        }

        private string at (int i) {
            return i >= 0 && i < norm.length && !used[i] ? norm[i] : "";
        }

        private void take (int from, int count) {
            for (int i = from; i < from + count && i < used.length; i++) used[i] = true;
        }

        private void take_lead (int i, string[] words) {
            string w = at (i - 1);
            foreach (string l in words) {
                if (w == l) {
                    used[i - 1] = true;
                    return;
                }
            }
        }

        private static int index_in (string word, string[] list) {
            for (int i = 0; i < list.length; i++) if (list[i] == word) return i;
            return -1;
        }

        private static int weekday_of (string word, bool allow_short) {
            int i = index_in (word, WEEKDAYS);
            if (i < 0) i = index_in (word, WEEKDAYS_IT);
            if (i < 0 && allow_short) i = index_in (word, WEEKDAYS_SHORT);
            return i < 0 ? 0 : i + 1;
        }

        private static int month_of (string word) {
            int i = index_in (word, MONTHS);
            if (i < 0) i = index_in (word, MONTHS_IT);
            if (i < 0) i = index_in (word, MONTHS_SHORT);
            if (i < 0) i = index_in (word, MONTHS_IT_SHORT);
            if (i < 0 && word == "sept") i = 8;
            return i < 0 ? 0 : i + 1;
        }

        private static int number_of (string word) {
            string w = word;
            if (w.has_suffix ("st") || w.has_suffix ("nd") || w.has_suffix ("rd") || w.has_suffix ("th")) w = w.substring (0, w.length - 2);
            if (w.length == 0 || w.length > 4) return -1;
            for (int i = 0; i < w.length; i++) if (!w[i].isdigit ()) return -1;
            return int.parse (w);
        }

        private static int count_of (string word) {
            if (word == "a" || word == "an" || word == "one" || word == "un" || word == "una" || word == "uno") return 1;
            if (word == "two" || word == "due") return 2;
            if (word == "three" || word == "tre") return 3;
            int n = number_of (word);
            return n > 0 && n < 1000 ? n : -1;
        }

        private static string unit_of (string word) {
            switch (word) {
                case "day": case "days": case "giorno": case "giorni": return "D";
                case "week": case "weeks": case "settimana": case "settimane": return "W";
                case "month": case "months": case "mese": case "mesi": return "M";
                case "year": case "years": case "anno": case "anni": return "Y";
                default: return "";
            }
        }

        private bool parse_clock (string word, out int h, out int m) {
            h = -1;
            m = 0;
            string w = word;
            int shift = -1;
            if (w.has_suffix ("am")) {
                shift = 0;
                w = w.substring (0, w.length - 2);
            } else if (w.has_suffix ("pm")) {
                shift = 12;
                w = w.substring (0, w.length - 2);
            }
            if (w.length == 0) return false;
            string[] parts = w.contains (":") ? w.split (":") : (w.contains (".") && shift >= 0 ? w.split (".") : new string[] { w });
            if (parts.length > 2) return false;
            foreach (string p in parts) {
                if (p.length == 0 || p.length > 2) return false;
                for (int i = 0; i < p.length; i++) if (!p[i].isdigit ()) return false;
            }
            h = int.parse (parts[0]);
            if (parts.length == 2) {
                if (parts[1].length != 2) return false;
                m = int.parse (parts[1]);
            }
            if (m > 59) return false;
            if (shift >= 0) {
                if (h < 1 || h > 12) return false;
                h = h % 12 + shift;
            } else if (h > 23) {
                return false;
            }
            return true;
        }

        private int match_time (int i) {
            string w = at (i);
            if (w == "") return 0;
            int h = -1, m = 0;
            bool lead = w == "at" || w == "alle" || w == "@" || w == "ore" || w == "all'";
            if (lead) {
                string next = at (i + 1);
                if (next == "noon" || next == "mezzogiorno") {
                    hour = 12;
                    minute = 0;
                    return 2;
                }
                if (next == "midnight" || next == "mezzanotte") {
                    hour = 0;
                    minute = 0;
                    return 2;
                }
                if (next != "" && parse_clock (next, out h, out m)) {
                    string after = at (i + 2);
                    if ((after == "am" || after == "pm") && !next.has_suffix ("am") && !next.has_suffix ("pm") && parse_clock (next + after, out h, out m)) {
                        hour = h;
                        minute = m;
                        return 3;
                    }
                    hour = h;
                    minute = m;
                    return 2;
                }
                return 0;
            }
            if (w == "noon" || w == "mezzogiorno") {
                hour = 12;
                minute = 0;
                return 1;
            }
            string after = at (i + 1);
            if ((after == "am" || after == "pm") && number_of (w) >= 0 && parse_clock (w + after, out h, out m)) {
                hour = h;
                minute = m;
                return 2;
            }
            bool clock_like = w.contains (":") || w.has_suffix ("am") || w.has_suffix ("pm");
            if (clock_like && parse_clock (w, out h, out m)) {
                hour = h;
                minute = m;
                return 1;
            }
            return 0;
        }

        private void set_day (DateTime d) {
            var l = d.to_local ();
            year = l.get_year ();
            month = l.get_month ();
            day = l.get_day_of_month ();
            weekday = 0;
        }

        private DateTime today () {
            return new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 0, 0, 0);
        }

        private int match_relative (int i) {
            string w = at (i);
            switch (w) {
                case "today":
                case "oggi":
                    set_day (today ());
                    return 1;
                case "tomorrow":
                case "domani":
                case "tmrw":
                    set_day (today ().add_days (1));
                    return 1;
                case "dopodomani":
                    set_day (today ().add_days (2));
                    return 1;
                case "tonight":
                case "stasera":
                    set_day (today ());
                    if (hour < 0) {
                        hour = 20;
                        minute = 0;
                    }
                    return 1;
            }
            if (w == "day" && at (i + 1) == "after" && at (i + 2) == "tomorrow") {
                set_day (today ().add_days (2));
                return 3;
            }
            if (w == "in" || w == "tra" || w == "fra") {
                int n = count_of (at (i + 1));
                string unit = unit_of (at (i + 2));
                if (n > 0 && unit != "") {
                    var t = today ();
                    switch (unit) {
                        case "D": t = t.add_days (n); break;
                        case "W": t = t.add_weeks (n); break;
                        case "M": t = t.add_months (n); break;
                        default: t = t.add_years (n); break;
                    }
                    set_day (t);
                    return 3;
                }
                return 0;
            }
            if ((w == "next" && at (i + 1) == "week") || (w == "settimana" && (at (i + 1) == "prossima" || at (i + 1) == "prossimo"))) {
                var t = today ();
                int dow = t.get_day_of_week ();
                set_day (t.add_days (8 - dow));
                return 2;
            }
            if ((w == "next" && at (i + 1) == "month") || (w == "mese" && at (i + 1) == "prossimo")) {
                var t = today ().add_months (1);
                set_day (new DateTime.local (t.get_year (), t.get_month (), 1, 0, 0, 0));
                return 2;
            }
            return 0;
        }

        private int match_weekday (int i) {
            string w = at (i);
            bool lead = w == "on" || w == "next" || w == "this" || w == "il" || w == "questo" || w == "questa";
            int start = lead ? i + 1 : i;
            int wd = weekday_of (at (start), lead);
            if (wd == 0) return 0;
            int count = start - i + 1;
            string post = at (start + 1);
            if (post == "prossimo" || post == "prossima") count++;
            weekday = wd;
            weekday_today = w == "this" || w == "questo" || w == "questa";
            year = month = day = 0;
            return count;
        }

        private int match_date (int i) {
            int start = i;
            while (start < i + 2 && (at (start) == "on" || at (start) == "il" || at (start) == "the")) start++;
            string a = at (start);
            if (a == "") return 0;
            if (a.length == 10 && a[4] == '-' && a[7] == '-') {
                int y = 0, m = 0, d = 0;
                if (a.scanf ("%d-%d-%d", out y, out m, out d) == 3 && valid (y, m, d)) {
                    year = y;
                    month = m;
                    day = d;
                    weekday = 0;
                    return start - i + 1;
                }
                return 0;
            }
            int d1 = number_of (a);
            int m1 = month_of (at (start + 1));
            int used_words = 0;
            int d = 0, m = 0;
            if (d1 >= 1 && d1 <= 31 && m1 > 0) {
                d = d1;
                m = m1;
                used_words = 2;
            } else {
                int m2 = month_of (a);
                int d2 = number_of (at (start + 1));
                if (m2 > 0 && d2 >= 1 && d2 <= 31) {
                    d = d2;
                    m = m2;
                    used_words = 2;
                }
            }
            if (used_words == 0) return 0;
            int y = number_of (at (start + used_words));
            if (y >= 1970 && y <= 2999 && at (start + used_words).length == 4) {
                used_words++;
            } else {
                y = now.get_year ();
                var candidate = valid (y, m, d) ? new DateTime.local (y, m, d, 0, 0, 0) : null;
                if (candidate == null || candidate.compare (today ()) < 0) y++;
            }
            if (!valid (y, m, d)) return 0;
            year = y;
            month = m;
            day = d;
            weekday = 0;
            return start - i + used_words;
        }

        private static bool valid (int y, int m, int d) {
            if (m < 1 || m > 12 || d < 1 || y < 1) return false;
            return d <= Date.get_days_in_month ((DateMonth) m, (DateYear) y);
        }

        private int match_repeat (int i) {
            string w = at (i);
            switch (w) {
                case "daily":
                    rrule = "FREQ=DAILY";
                    return 1;
                case "weekly":
                    rrule = "FREQ=WEEKLY";
                    return 1;
                case "monthly":
                    rrule = "FREQ=MONTHLY";
                    return 1;
                case "yearly":
                case "annually":
                    rrule = "FREQ=YEARLY";
                    return 1;
            }
            if (w != "every" && w != "ogni") return 0;
            string a = at (i + 1);
            if (a == "") return 0;
            if (a == "weekday" || a == "weekdays" || a == "feriale") {
                rrule = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR";
                rule_weekdays = true;
                return 2;
            }
            if (a == "giorno" && at (i + 2) == "feriale") {
                rrule = "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR";
                rule_weekdays = true;
                return 3;
            }
            int wd = weekday_of (a, true);
            if (wd > 0) {
                rrule = "FREQ=WEEKLY;BYDAY=" + BYDAY[wd - 1];
                rule_weekday = wd;
                return 2;
            }
            int n = 1;
            int consumed = 1;
            if (a == "other" || a == "altro") {
                n = 2;
                consumed = 2;
            } else {
                int c = count_of (a);
                if (c > 0 && a != "a" && a != "an") {
                    n = c;
                    consumed = 2;
                }
            }
            string unit = unit_of (at (i + consumed));
            if (unit == "") return 0;
            string freq;
            switch (unit) {
                case "D": freq = "DAILY"; break;
                case "W": freq = "WEEKLY"; break;
                case "M": freq = "MONTHLY"; break;
                default: freq = "YEARLY"; break;
            }
            rrule = "FREQ=" + freq + (n > 1 ? ";INTERVAL=%d".printf (n) : "");
            return consumed + 1;
        }

        private int match_priority (int i) {
            string w = at (i);
            if (!w.has_prefix ("!")) return 0;
            switch (w) {
                case "!high":
                case "!h":
                case "!urgent":
                case "!alta":
                case "!!!":
                    return 1;
                case "!medium":
                case "!med":
                case "!media":
                case "!!":
                    return 2;
                case "!low":
                case "!bassa":
                    return 3;
                default:
                    return 0;
            }
        }

        private QuickEntry run (string text) {
            var e = new QuickEntry ();
            string[] date_leads = { "by", "due", "before", "entro", "per", "for" };
            for (int i = 0; i < norm.length; i++) {
                if (used[i]) continue;
                if (orig[i].has_prefix ("#") && orig[i].length > 1) {
                    string tag = clean_tag (orig[i]);
                    bool skip = false;
                    if (ignored_tags != null) foreach (string ig in ignored_tags) if (ig.casefold () == tag.casefold ()) skip = true;
                    if (tag != "" && !skip) {
                        bool dup = false;
                        foreach (string t in e.tags) if (t.casefold () == tag.casefold ()) dup = true;
                        if (!dup) e.tags.add (tag);
                        take (i, 1);
                        continue;
                    }
                }
                int pr = priorities ? match_priority (i) : 0;
                if (pr > 0) {
                    e.priority = pr == 1 ? Priority.HIGH : (pr == 2 ? Priority.MEDIUM : Priority.LOW);
                    take (i, 1);
                    continue;
                }
                int n = repeats ? match_repeat (i) : 0;
                if (n > 0) {
                    take (i, n);
                    continue;
                }
                if (!dates) continue;
                n = match_relative (i);
                if (n == 0) n = match_date (i);
                if (n == 0) n = match_weekday (i);
                if (n > 0) {
                    take (i, n);
                    take_lead (i, date_leads);
                    continue;
                }
                n = match_time (i);
                if (n > 0) {
                    take (i, n);
                    continue;
                }
            }
            string[] rest = {};
            for (int i = 0; i < orig.length; i++) if (!used[i]) rest += orig[i];
            e.title = string.joinv (" ", rest).strip ();
            if (e.title == "") e.title = text.strip ();
            e.rrule = rrule;
            resolve (e);
            return e;
        }

        private void resolve (QuickEntry e) {
            DateTime? date = null;
            var t = today ();
            if (year > 0) {
                date = new DateTime.local (year, month, day, 0, 0, 0);
            } else if (weekday > 0) {
                int dow = t.get_day_of_week ();
                int ahead = (weekday - dow + 7) % 7;
                if (ahead == 0 && !weekday_today) ahead = 7;
                date = t.add_days (ahead);
            } else if (rrule != "") {
                if (rule_weekday > 0 || rule_weekdays) {
                    for (int k = 0; k < 7; k++) {
                        var c = t.add_days (k);
                        int dow = c.get_day_of_week ();
                        bool fits = rule_weekday > 0 ? dow == rule_weekday : dow <= 5;
                        if (!fits) continue;
                        if (k == 0 && hour >= 0 && !later_today (hour, minute)) continue;
                        date = c;
                        break;
                    }
                } else {
                    date = hour >= 0 && !later_today (hour, minute) ? t.add_days (1) : t;
                }
            } else if (hour >= 0) {
                date = later_today (hour, minute) ? t : t.add_days (1);
            }
            if (date == null) return;
            if (hour >= 0) {
                e.due = new DateTime.local (date.get_year (), date.get_month (), date.get_day_of_month (), hour, minute, 0);
                e.due_has_time = true;
            } else {
                e.due = date;
                e.due_has_time = false;
            }
        }

        private bool later_today (int h, int m) {
            return h * 60 + m > now.get_hour () * 60 + now.get_minute ();
        }
    }
}
