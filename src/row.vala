using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Tasks {

    public enum DropPlace {
        BEFORE,
        INTO,
        AFTER
    }

    public class TaskRow : ListBoxRow {
        public Task task { get; construct; }
        public CheckButton check;
        private TasksWindow win;
        private string drop_class = "";

        public TaskRow (TasksWindow win, TaskStore store, Task task, int depth, bool tree, bool context, DateTime now) {
            Object (task: task);
            this.win = win;
            add_css_class ("tasks-row");
            if (task.completed) add_css_class ("tasks-row-done");

            var box = new Box (Orientation.HORIZONTAL, 10);
            box.margin_start = 6 + depth * 26;
            box.margin_end = 8;

            bool parent = store.has_children (task);
            if (tree) {
                if (parent) {
                    var expander = new Button.from_icon_name (task.expanded ? "pan-down-symbolic" : "pan-end-symbolic");
                    expander.add_css_class ("flat");
                    expander.add_css_class ("circular");
                    expander.add_css_class ("tasks-expander");
                    expander.valign = Align.CENTER;
                    expander.tooltip_text = task.expanded ? _("Hide Subtasks") : _("Show Subtasks");
                    expander.clicked.connect (() => win.toggle_expanded (task));
                    box.append (expander);
                } else {
                    var spacer = new Box (Orientation.HORIZONTAL, 0);
                    spacer.set_size_request (24, -1);
                    box.append (spacer);
                }
            }

            check = new CheckButton ();
            check.active = task.completed;
            check.valign = Align.CENTER;
            check.add_css_class ("tasks-check");
            check.tooltip_text = task.completed ? _("Mark as Not Done") : _("Mark as Done");
            check.toggled.connect (() => {
                if (check.active != task.completed) win.set_done (task, check.active);
            });
            box.append (check);

            var texts = new Box (Orientation.VERTICAL, 2);
            texts.valign = Align.CENTER;
            texts.hexpand = true;
            var title = new Label (task.title != "" ? task.title : _("Untitled Task"));
            title.xalign = 0;
            title.ellipsize = Pango.EllipsizeMode.END;
            title.add_css_class ("tasks-title");
            if (task.title == "") title.add_css_class ("dim-label");
            texts.append (title);

            var meta = new Box (Orientation.HORIZONTAL, 10);
            if (task.due != null) {
                var due = new Label (TaskFormat.due (task, now));
                due.add_css_class ("tasks-meta");
                int key = TaskStore.date_key (task.due), today = TaskStore.date_key (now);
                bool overdue = !task.completed && (key < today || (key == today && task.due_has_time && task.due.compare (now) < 0));
                if (overdue) due.add_css_class ("tasks-overdue");
                else if (key == today && !task.completed) due.add_css_class ("tasks-due-today");
                meta.append (due);
            }
            if (task.rrule != "") meta.append (meta_icon ("media-playlist-repeat-symbolic", RepeatRule.describe_text (task.rrule)));
            if (task.reminder_time () != null) meta.append (meta_icon ("alarm-symbolic", _("Reminder at %s").printf (TaskFormat.moment (task.reminder_time (), now))));
            if (task.notes.strip () != "") meta.append (meta_icon ("text-x-generic-symbolic", _("Has notes")));
            if (context) {
                var list = store.list (task.list_id);
                var p = store.parent_of (task);
                string where = list != null ? list.name : "";
                if (p != null) where = where != "" ? _("%s, in %s").printf (where, p.title) : p.title;
                if (where != "") {
                    var l = new Label (where);
                    l.add_css_class ("tasks-meta");
                    l.ellipsize = Pango.EllipsizeMode.END;
                    meta.append (l);
                }
            }
            foreach (string tag in task.tags) {
                var chip = new Label ("#" + tag);
                chip.add_css_class ("tasks-tag");
                meta.append (chip);
            }
            if (meta.get_first_child () != null) texts.append (meta);
            box.append (texts);

            if (parent) {
                int done, total;
                store.progress (task, out done, out total);
                var ring = new CircularProgress (20);
                ring.fraction = total > 0 ? (double) done / total : 0;
                ring.add_css_class ("tasks-progress");
                ring.tooltip_text = ngettext ("%d of %d subtask done", "%d of %d subtasks done", total).printf (done, total);
                box.append (ring);
                var count = new Label ("%d/%d".printf (done, total));
                count.add_css_class ("tasks-count");
                count.valign = Align.CENTER;
                box.append (count);
            }
            if (task.priority != Priority.NONE) {
                var flag = new Image.from_icon_name ("tasks-priority-symbolic");
                flag.pixel_size = 16;
                flag.valign = Align.CENTER;
                flag.add_css_class ("tasks-priority-%s".printf (task.priority == Priority.HIGH ? "high" : (task.priority == Priority.MEDIUM ? "medium" : "low")));
                flag.tooltip_text = _("%s priority").printf (task.priority.label ());
                box.append (flag);
            }
            if (task.trashed) {
                var restore = new Button.from_icon_name ("edit-undo-symbolic");
                restore.add_css_class ("flat");
                restore.valign = Align.CENTER;
                restore.tooltip_text = _("Restore");
                restore.clicked.connect (() => win.restore_task (task));
                box.append (restore);
                check.sensitive = false;
            }
            child = Singularity.Animation.ListAnimator.wrap (box);
            Singularity.Animation.ListAnimator.set_key (this, task.uid);

            var click = new GestureClick ();
            click.button = 3;
            click.pressed.connect ((n, x, y) => win.task_menu (this, x, y));
            add_controller (click);
            var press = new GestureLongPress ();
            press.pressed.connect ((x, y) => win.task_menu (this, x, y));
            add_controller (press);

            if (task.trashed) return;
            var drag = new DragSource ();
            drag.actions = Gdk.DragAction.MOVE;
            drag.prepare.connect ((x, y) => {
                var v = Value (typeof (string));
                v.set_string (task.uid);
                return new Gdk.ContentProvider.for_value (v);
            });
            drag.drag_begin.connect ((d) => add_css_class ("tasks-dragging"));
            drag.drag_end.connect ((d, del) => remove_css_class ("tasks-dragging"));
            add_controller (drag);
            Singularity.Animation.DragLift.attach (drag, this);

            if (!tree) return;
            var drop = new DropTarget (typeof (string), Gdk.DragAction.MOVE);
            drop.motion.connect ((x, y) => {
                show_drop (place_for (y));
                return Gdk.DragAction.MOVE;
            });
            drop.leave.connect (() => apply_drop_class (""));
            drop.drop.connect ((value, x, y) => {
                apply_drop_class ("");
                string? uid = value.get_string ();
                if (uid == null || uid == task.uid) return false;
                return win.drop_task (uid, task, place_for (y));
            });
            add_controller (drop);
        }

        private DropPlace place_for (double y) {
            double h = get_height ();
            if (h <= 0) return DropPlace.AFTER;
            if (y < h * 0.3) return DropPlace.BEFORE;
            if (y > h * 0.7) return DropPlace.AFTER;
            return DropPlace.INTO;
        }

        private void apply_drop_class (string cls) {
            if (drop_class != "") remove_css_class (drop_class);
            drop_class = cls;
            if (cls != "") add_css_class (cls);
        }

        private void show_drop (DropPlace place) {
            switch (place) {
                case DropPlace.BEFORE: apply_drop_class ("tasks-drop-before"); break;
                case DropPlace.INTO: apply_drop_class ("tasks-drop-into"); break;
                default: apply_drop_class ("tasks-drop-after"); break;
            }
        }

        private static Image meta_icon (string name, string tip) {
            var i = new Image.from_icon_name (name);
            i.pixel_size = 12;
            i.add_css_class ("tasks-meta");
            i.tooltip_text = tip;
            return i;
        }
    }
}
