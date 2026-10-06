namespace Singularity.Apps.Tasks {

    public class TaskFormat : Object {
        public static string day (DateTime date, DateTime now) {
            var d = date.to_local ();
            var n = now.to_local ();
            var today = new DateTime.local (n.get_year (), n.get_month (), n.get_day_of_month (), 0, 0, 0);
            var that = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), 0, 0, 0);
            int days = (int) Math.round (that.difference (today) / (double) TimeSpan.DAY);
            if (days == 0) return _("Today");
            if (days == 1) return _("Tomorrow");
            if (days == -1) return _("Yesterday");
            if (days > 1 && days < 7) return d.format ("%A");
            if (d.get_year () == n.get_year ()) return d.format ("%-d %b");
            return d.format ("%-d %b %Y");
        }

        public static string time (DateTime date) {
            return date.to_local ().format ("%H:%M");
        }

        public static string due (Task t, DateTime now) {
            if (t.due == null) return "";
            string d = day (t.due, now);
            return t.due_has_time ? _("%s, %s").printf (d, time (t.due)) : d;
        }

        public static string moment (DateTime? at, DateTime now) {
            if (at == null) return "";
            return _("%s, %s").printf (day (at, now), time (at));
        }

        public static string reminder_choice (int minutes) {
            if (minutes < 0) return _("Never");
            if (minutes == 0) return _("When Due");
            if (minutes % 1440 == 0) return ngettext ("%d Day Before", "%d Days Before", minutes / 1440).printf (minutes / 1440);
            if (minutes % 60 == 0) return ngettext ("%d Hour Before", "%d Hours Before", minutes / 60).printf (minutes / 60);
            return ngettext ("%d Minute Before", "%d Minutes Before", minutes).printf (minutes);
        }
    }
}
