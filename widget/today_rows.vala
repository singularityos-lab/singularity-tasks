using Gtk;
using Singularity.Apps.Tasks;

namespace SingularityTasksWidget {

    public class TodayRows : Object {
        private static CssProvider? css = null;

        public static void ensure_css () {
            if (css != null) return;
            css = new CssProvider ();
            css.load_from_string ("""
.overview-tasks {
    border-radius: 20px;
    background: alpha(@window_bg_color, 0.35);
    border: 1px solid alpha(@window_fg_color, 0.08);
    box-shadow: 0 1px 2px alpha(black, 0.18) inset, 0 1px 4px alpha(black, 0.12);
    padding: 14px 14px 12px 14px;
}
.overview-tasks-count {
    font-size: 12px;
    font-feature-settings: "tnum";
    opacity: 0.6;
}
.overview-tasks-row {
    padding: 2px 4px;
    border-radius: 8px;
}
.overview-tasks-row:hover {
    background-color: alpha(@window_fg_color, 0.06);
}
.overview-tasks-row.done .overview-tasks-title {
    text-decoration: line-through;
    opacity: 0.55;
}
.overview-tasks-title {
    padding: 0;
    min-height: 0;
}
.overview-tasks-meta {
    font-size: 11px;
    opacity: 0.65;
}
.overview-tasks-meta.overdue {
    color: @error_color;
    opacity: 1;
    font-weight: 600;
}
.overview-tasks-entry {
    border-radius: 10px;
    min-height: 30px;
}
""");
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), css, STYLE_PROVIDER_PRIORITY_USER + 1);
        }

        public static Widget row (Singularity.Apps.Tasks.Task t, DateTime now) {
            var row = new Gtk.Box (Orientation.HORIZONTAL, 8);
            row.add_css_class ("overview-tasks-row");
            var check = new CheckButton ();
            check.valign = Align.CENTER;
            check.tooltip_text = _("Mark as Done");
            string uid = t.uid;
            check.toggled.connect (() => {
                if (!check.active) return;
                check.sensitive = false;
                row.add_css_class ("done");
                TodayRows.call_app ("complete-task", new Variant.string (uid), () => {
                    check.active = false;
                    check.sensitive = true;
                    row.remove_css_class ("done");
                });
            });
            row.append (check);

            var open = new Button ();
            open.has_frame = false;
            open.hexpand = true;
            open.add_css_class ("overview-tasks-title");
            var texts = new Gtk.Box (Orientation.VERTICAL, 0);
            var title = new Label (t.title != "" ? t.title : _("Untitled Task"));
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.END;
            texts.append (title);
            bool overdue = TaskStore.date_key (t.due) < TaskStore.date_key (now) || (t.due_has_time && t.due.compare (now) < 0);
            string meta_text = overdue ? _("Overdue, %s").printf (TaskFormat.due (t, now)) : (t.due_has_time ? TaskFormat.time (t.due) : "");
            if (meta_text != "") {
                var meta = new Label (meta_text);
                meta.xalign = 0;
                meta.add_css_class ("overview-tasks-meta");
                if (overdue) meta.add_css_class ("overdue");
                texts.append (meta);
            }
            open.child = texts;
            open.clicked.connect (() => TodayRows.call_app ("show-task", new Variant.string (uid), null));
            row.append (open);
            return row;
        }

        public delegate void FailureCallback ();

        public static void call_app (string action, Variant? parameter, owned FailureCallback? failed) {
            var platform = new VariantBuilder (new VariantType ("a{sv}"));
            var args = new VariantBuilder (new VariantType ("av"));
            if (parameter != null) args.add ("v", parameter);
            Bus.get.begin (BusType.SESSION, null, (obj, res) => {
                try {
                    var bus = Bus.get.end (res);
                    bus.call.begin ("dev.sinty.tasks", "/dev/sinty/tasks", "org.freedesktop.Application",
                        "ActivateAction", new Variant ("(s@av@a{sv})", action, args.end (), platform.end ()),
                        null, DBusCallFlags.NONE, 10000, null, (o, r) => {
                            try {
                                bus.call.end (r);
                            } catch (Error e) {
                                warning ("tasks widget: %s", e.message);
                                if (failed != null) failed ();
                            }
                        });
                } catch (Error e) {
                    warning ("tasks widget: %s", e.message);
                    if (failed != null) failed ();
                }
            });
        }
    }
}
