namespace Singularity.Apps.Tasks {

    public enum FocusPhase {
        IDLE,
        FOCUS,
        BREAK
    }

    public class FocusTimer : Object {
        public FocusPhase phase { get; private set; default = FocusPhase.IDLE; }
        public string task_uid { get; private set; default = ""; }
        public bool paused { get; private set; default = false; }
        public int focus_length = 25 * 60;
        public int break_length = 5 * 60;
        private int64 phase_start;
        private int64 paused_at;
        private int64 paused_total;
        private int length;

        public signal void phase_finished (FocusPhase finished, string task_uid, int64 focused_seconds);

        public bool running {
            get { return phase != FocusPhase.IDLE; }
        }

        public void start (string uid, int64 now) {
            task_uid = uid;
            begin (FocusPhase.FOCUS, now);
        }

        public void retarget (string old_uid, string new_uid) {
            if (task_uid == old_uid) task_uid = new_uid;
        }

        private void begin (FocusPhase p, int64 now) {
            phase = p;
            phase_start = now;
            paused = false;
            paused_total = 0;
            length = p == FocusPhase.FOCUS ? focus_length : break_length;
        }

        public int64 elapsed (int64 now) {
            if (phase == FocusPhase.IDLE) return 0;
            int64 end = paused ? paused_at : now;
            return int64.max (0, end - phase_start - paused_total);
        }

        public int remaining (int64 now) {
            if (phase == FocusPhase.IDLE) return 0;
            return (int) int64.max (0, length - elapsed (now));
        }

        public double fraction (int64 now) {
            if (phase == FocusPhase.IDLE || length <= 0) return 0;
            return double.min (1.0, (double) elapsed (now) / length);
        }

        public void pause (int64 now) {
            if (phase == FocusPhase.IDLE || paused) return;
            paused = true;
            paused_at = now;
        }

        public void resume (int64 now) {
            if (!paused) return;
            paused_total += now - paused_at;
            paused = false;
        }

        public int64 stop (int64 now) {
            int64 focused = phase == FocusPhase.FOCUS ? int64.min (elapsed (now), length) : 0;
            phase = FocusPhase.IDLE;
            paused = false;
            string uid = task_uid;
            task_uid = "";
            if (focused > 0) phase_finished (FocusPhase.IDLE, uid, focused);
            return focused;
        }

        public void tick (int64 now) {
            if (phase == FocusPhase.IDLE || paused) return;
            if (remaining (now) > 0) return;
            string uid = task_uid;
            if (phase == FocusPhase.FOCUS) {
                int64 focused = length;
                int64 overshoot = elapsed (now) - length;
                begin (FocusPhase.BREAK, now - overshoot);
                phase_finished (FocusPhase.FOCUS, uid, focused);
                tick (now);
            } else {
                phase = FocusPhase.IDLE;
                task_uid = "";
                phase_finished (FocusPhase.BREAK, uid, 0);
            }
        }

        public static string clock (int seconds) {
            int s = int.max (0, seconds);
            if (s >= 3600) return "%d:%02d:%02d".printf (s / 3600, (s / 60) % 60, s % 60);
            return "%02d:%02d".printf (s / 60, s % 60);
        }

        public static string spent (int64 seconds) {
            int64 minutes = seconds / 60;
            if (minutes < 1) return ngettext ("%d second", "%d seconds", (ulong) seconds).printf ((int) seconds);
            if (minutes < 60) return ngettext ("%d minute", "%d minutes", (ulong) minutes).printf ((int) minutes);
            int64 h = minutes / 60, m = minutes % 60;
            if (m == 0) return ngettext ("%d hour", "%d hours", (ulong) h).printf ((int) h);
            return _("%s %s").printf (ngettext ("%d hour", "%d hours", (ulong) h).printf ((int) h), ngettext ("%d minute", "%d minutes", (ulong) m).printf ((int) m));
        }
    }
}
