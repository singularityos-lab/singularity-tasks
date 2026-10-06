using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Tasks {

    public class TaskDetail : Box {
        private const int[] REMINDERS = { -1, 0, 5, 15, 30, 60, 1440 };

        public Task task { get; construct; }
        private TasksWindow win;
        private TaskStore store;
        private Entry title_entry;

        public TaskDetail (TasksWindow win, TaskStore store, Task task) {
            Object (task: task, orientation: Orientation.VERTICAL, spacing: 16);
            this.win = win;
            this.store = store;
            add_css_class ("tasks-panel");
            var now = new DateTime.now_local ();
            var home = store.list (task.list_id);
            bool locked = home != null && home.read_only;

            var top = new Box (Orientation.HORIZONTAL, 8);
            var check = new CheckButton ();
            check.active = task.completed;
            check.valign = Align.CENTER;
            check.add_css_class ("tasks-check");
            check.tooltip_text = _("Done");
            check.sensitive = !task.trashed && !locked;
            check.toggled.connect (() => {
                if (check.active != task.completed) win.set_done (task, check.active);
            });
            top.append (check);
            title_entry = new Entry ();
            title_entry.text = task.title;
            title_entry.placeholder_text = _("Task Title");
            title_entry.hexpand = true;
            title_entry.editable = !locked;
            title_entry.add_css_class ("tasks-detail-title");
            title_entry.changed.connect (() => {
                task.title = title_entry.text;
                win.task_edited (task, false);
            });
            top.append (title_entry);
            var close = new Button.from_icon_name ("window-close-symbolic");
            close.add_css_class ("flat");
            close.add_css_class ("circular");
            close.valign = Align.CENTER;
            close.tooltip_text = _("Close");
            close.clicked.connect (() => win.close_detail ());
            top.append (close);
            append (top);

            var parent = store.parent_of (task);
            if (parent != null) {
                var up = new Button.with_label (_("Part of %s").printf (parent.title != "" ? parent.title : _("Untitled Task")));
                up.add_css_class ("flat");
                up.add_css_class ("tasks-parent-link");
                up.halign = Align.START;
                up.clicked.connect (() => win.show_task (parent));
                append (up);
            }

            var notes_frame = new ScrolledWindow ();
            notes_frame.hscrollbar_policy = PolicyType.NEVER;
            notes_frame.min_content_height = 96;
            notes_frame.max_content_height = 240;
            notes_frame.propagate_natural_height = true;
            notes_frame.add_css_class ("tasks-notes");
            var notes = new TextView ();
            notes.wrap_mode = WrapMode.WORD_CHAR;
            notes.buffer.text = task.notes;
            notes.accepts_tab = false;
            notes.editable = !locked;
            notes.top_margin = notes.bottom_margin = 10;
            notes.left_margin = notes.right_margin = 12;
            notes.update_property (AccessibleProperty.LABEL, _("Notes"), -1);
            notes.buffer.changed.connect (() => {
                task.notes = notes.buffer.text;
                win.task_edited (task, false);
            });
            notes_frame.child = notes;
            var notes_hint = new Label (_("Notes"));
            notes_hint.xalign = 0;
            notes_hint.add_css_class ("tasks-panel-heading");
            append (notes_hint);
            append (notes_frame);

            var when = new PreferencesGroup (_("When"));
            var due_row = new ActionRow (_("Due"), null, "x-office-calendar-symbolic");
            var due_button = new MenuButton ();
            due_button.label = task.due != null ? TaskFormat.day (task.due, now) : _("No Date");
            due_button.valign = Align.CENTER;
            due_button.popover = build_date_popover ();
            due_row.add_suffix (due_button);
            due_row.activated.connect (() => due_button.popup ());
            when.add_row (due_row);

            if (task.due != null) {
                var at_time = new SwitchRow (_("At a Set Time"), null, task.due_has_time);
                when.add_row (at_time);
                var time_row = new ActionRow (_("Time"), null, "alarm-symbolic");
                var local = task.due.to_local ();
                var picker = new TimePicker ("%02d:%02d".printf (local.get_hour (), local.get_minute ()));
                time_row.add_suffix (picker);
                time_row.visible = task.due_has_time;
                when.add_row (time_row);
                at_time.switch_btn.notify["active"].connect (() => {
                    var d = task.due.to_local ();
                    if (at_time.active) {
                        task.due = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), 9, 0, 0);
                        picker.time = "09:00";
                    } else {
                        task.due = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), 0, 0, 0);
                    }
                    task.due_has_time = at_time.active;
                    time_row.visible = at_time.active;
                    task.reminded = 0;
                    win.task_edited (task, true);
                });
                picker.changed.connect (() => {
                    var d = task.due.to_local ();
                    var parts = picker.time.split (":");
                    task.due = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), int.parse (parts[0]), int.parse (parts[1]), 0);
                    task.reminded = 0;
                    win.task_edited (task, true);
                });
            }

            string[] labels = {};
            string current = TaskFormat.reminder_choice (task.reminder_minutes);
            string custom = "";
            if (task.reminder_at != null) {
                custom = _("At %s").printf (TaskFormat.moment (task.reminder_at, now));
                labels += custom;
                current = custom;
            }
            foreach (int m in REMINDERS) labels += TaskFormat.reminder_choice (m);
            var remind = new SelectionRow (_("Remind Me"), labels, current);
            remind.icon_name = "alarm-symbolic";
            if (task.due == null && task.reminder_at == null) {
                remind.sensitive = false;
                remind.subtitle = _("Set a due date first");
            }
            remind.selected.connect ((item) => {
                if (item == custom) return;
                foreach (int m in REMINDERS) {
                    if (TaskFormat.reminder_choice (m) == item) {
                        task.reminder_minutes = m;
                        task.reminder_at = null;
                        task.reminded = 0;
                    }
                }
                win.task_edited (task, true);
            });
            when.add_row (remind);
            build_repeat (when);
            when.sensitive = !locked;
            append (when);

            var details = new PreferencesGroup ();
            Priority[] levels = { Priority.NONE, Priority.LOW, Priority.MEDIUM, Priority.HIGH };
            string[] level_names = {};
            foreach (var p in levels) level_names += p.label ();
            var priority_row = new SelectionRow (_("Priority"), level_names, task.priority.label ());
            priority_row.icon_name = "tasks-priority-symbolic";
            priority_row.selected.connect ((name) => {
                foreach (var p in levels) {
                    if (p.label () == name) task.priority = p;
                }
                win.task_edited (task, true);
            });
            details.add_row (priority_row);

            var tags = new EntryRow (_("Tags, separated by commas"), "tasks-tag-symbolic");
            tags.text = task.tags_text ();
            tags.entry_changed.connect (() => {
                task.set_tags_from_text (tags.text);
                win.task_edited (task, false);
            });
            details.add_row (tags);

            if (task.parent_uid == "" && store.lists.size > 1 && !task.trashed && !locked) {
                string[] names = {};
                foreach (var l in store.lists) if (!l.read_only) names += l.label ();
                var list = store.list (task.list_id);
                var list_row = new SelectionRow (_("List"), names, list != null ? list.label () : "");
                list_row.icon_name = "view-list-symbolic";
                list_row.selected.connect ((name) => {
                    foreach (var l in store.lists) {
                        if (!l.read_only && l.label () == name) {
                            win.move_to_list (task, l);
                            break;
                        }
                    }
                });
                details.add_row (list_row);
            }
            if (home != null && home.online) {
                string where = home.status != "" ? home.status : (locked ? _("Read only") : _("Synced with this account"));
                details.add_row (new ActionRow (home.account_name, where, home.icon_name));
            }
            priority_row.sensitive = !locked;
            tags.sensitive = !locked;
            append (details);

            if (!task.trashed) {
                var focus = new PreferencesGroup ();
                bool running = win.focus_task_uid () == task.uid;
                string spent = task.focus_seconds > 0 ? _("Focused for %s").printf (FocusTimer.spent (task.focus_seconds)) : _("No focus sessions yet");
                var focus_row = new ActionRow (_("Focus Timer"), spent, "alarm-symbolic");
                var focus_btn = new Button.with_label (running ? _("Stop") : _("Start"));
                focus_btn.add_css_class ("pill");
                if (!running) focus_btn.add_css_class ("suggested-action");
                focus_btn.valign = Align.CENTER;
                focus_btn.tooltip_text = running ? _("Stop Focus Timer (Ctrl+Shift+T)") : _("Start Focus Timer (Ctrl+T)");
                focus_btn.clicked.connect (() => {
                    if (win.focus_task_uid () == task.uid) win.stop_focus ();
                    else win.focus_on (task);
                });
                focus_row.add_suffix (focus_btn);
                focus.add_row (focus_row);
                append (focus);
            }

            var subs = new PreferencesGroup (_("Subtasks"));
            foreach (var c in store.children (task.list_id, task.uid)) {
                var child = c;
                var row = new ActionRow (c.title != "" ? c.title : _("Untitled Task"), c.due != null ? TaskFormat.due (c, now) : null);
                var cc = new CheckButton ();
                cc.active = c.completed;
                cc.sensitive = !locked;
                cc.valign = Align.CENTER;
                cc.margin_end = 10;
                cc.add_css_class ("tasks-check");
                cc.toggled.connect (() => {
                    if (cc.active != child.completed) win.set_done (child, cc.active);
                });
                row.add_prefix (cc);
                var open = new Image.from_icon_name ("go-next-symbolic");
                row.add_suffix (open);
                row.activated.connect (() => win.show_task (child));
                subs.add_row (row);
            }
            if (!task.trashed && !locked) {
                var add = new EntryRow (_("Add a Subtask"), "list-add-symbolic");
                add.entry_activated.connect (() => {
                    string text = add.text.strip ();
                    if (text == "") return;
                    win.add_subtask (task, text);
                });
                subs.add_row (add);
            }
            append (subs);

            var foot = new Box (Orientation.HORIZONTAL, 8);
            var created = new Label (_("Created %s").printf (TaskFormat.moment (task.created, now)));
            created.add_css_class ("dim-label");
            created.add_css_class ("caption");
            created.hexpand = true;
            created.xalign = 0;
            foot.append (created);
            if (task.trashed) {
                var restore = new Button.with_label (_("Restore"));
                restore.add_css_class ("pill");
                restore.clicked.connect (() => win.restore_task (task));
                foot.append (restore);
            } else if (!locked) {
                var trash = new Button.from_icon_name ("user-trash-symbolic");
                trash.add_css_class ("flat");
                trash.add_css_class ("destructive-action");
                trash.tooltip_text = home != null && home.online ? _("Delete…") : _("Move to Trash");
                trash.clicked.connect (() => win.trash_task (task));
                foot.append (trash);
            }
            append (foot);
        }

        private void build_repeat (PreferencesGroup when) {
            var rule = RepeatRule.parse (task.rrule);
            string never = _("Never");
            string daily = _("Every Day");
            string weekdays = _("Every Weekday");
            string weekly = _("Every Week");
            string monthly = _("Every Month");
            string yearly = _("Every Year");
            string[] items = { never, daily, weekdays, weekly, monthly, yearly };
            string current = never;
            if (rule != null) {
                if (rule.is_weekdays ()) current = weekdays;
                else if (rule.frequency == RepeatFrequency.DAILY) current = daily;
                else if (rule.frequency == RepeatFrequency.WEEKLY) current = weekly;
                else if (rule.frequency == RepeatFrequency.MONTHLY) current = monthly;
                else current = yearly;
            } else if (task.rrule != "") {
                current = task.rrule;
                items += current;
            }
            var repeat = new SelectionRow (_("Repeat"), items, current);
            repeat.icon_name = "media-playlist-repeat-symbolic";
            repeat.subtitle = rule != null ? rule.describe () : (task.rrule != "" ? _("Kept as imported") : "");
            repeat.sensitive = !task.trashed;
            when.add_row (repeat);
            repeat.selected.connect ((item) => {
                if (item == current) return;
                var r = rule ?? new RepeatRule ();
                r.days.clear ();
                r.interval = 1;
                if (item == never) {
                    task.rrule = "";
                } else {
                    if (item == daily) r.frequency = RepeatFrequency.DAILY;
                    else if (item == weekly) r.frequency = RepeatFrequency.WEEKLY;
                    else if (item == monthly) r.frequency = RepeatFrequency.MONTHLY;
                    else if (item == yearly) r.frequency = RepeatFrequency.YEARLY;
                    else if (item == weekdays) {
                        r.frequency = RepeatFrequency.WEEKLY;
                        r.interval = 1;
                        for (int d = 1; d <= 5; d++) r.days.add (d);
                    } else {
                        return;
                    }
                    if (task.due == null) {
                        var n = new DateTime.now_local ();
                        task.due = new DateTime.local (n.get_year (), n.get_month (), n.get_day_of_month (), 0, 0, 0);
                        task.due_has_time = false;
                    }
                    task.rrule = r.to_string ();
                }
                win.task_edited (task, true);
                Idle.add (() => {
                    win.show_task (task);
                    return Source.REMOVE;
                });
            });
            if (rule == null || rule.is_weekdays ()) return;
            string unit;
            switch (rule.frequency) {
                case RepeatFrequency.DAILY: unit = _("Days"); break;
                case RepeatFrequency.WEEKLY: unit = _("Weeks"); break;
                case RepeatFrequency.MONTHLY: unit = _("Months"); break;
                default: unit = _("Years"); break;
            }
            var interval = new SpinRow (_("Every"), unit, 1, 99, 1, rule.interval);
            interval.sensitive = !task.trashed;
            when.add_row (interval);
            interval.spin_btn.value_changed.connect (() => {
                rule.interval = (int) interval.value;
                task.rrule = rule.to_string ();
                repeat.subtitle = rule.describe ();
                win.task_edited (task, false);
            });
            if (rule.frequency != RepeatFrequency.WEEKLY) return;
            var days_row = new ActionRow (_("On"));
            var days = new Box (Orientation.HORIZONTAL, 0);
            days.valign = Align.CENTER;
            for (int d = 1; d <= 7; d++) {
                int day = d;
                var b = new ToggleButton.with_label (RepeatRule.day_name (d).substring (0, RepeatRule.day_name (d).index_of_nth_char (2)));
                b.add_css_class ("flat");
                b.add_css_class ("circular");
                b.add_css_class ("tasks-day");
                b.tooltip_text = RepeatRule.day_name (d);
                b.active = rule.days.contains (d);
                b.sensitive = !task.trashed;
                b.toggled.connect (() => {
                    if (b.active && !rule.days.contains (day)) rule.days.add (day);
                    if (!b.active) rule.days.remove (day);
                    rule.days.sort ((x, y) => x - y);
                    task.rrule = rule.to_string ();
                    repeat.subtitle = rule.describe ();
                    win.task_edited (task, false);
                });
                days.append (b);
            }
            days_row.add_suffix (days);
            when.add_row (days_row);
        }

        public void focus_title () {
            title_entry.grab_focus ();
        }

        private Popover build_date_popover () {
            var pop = new Popover ();
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_top = box.margin_bottom = box.margin_start = box.margin_end = 8;
            var quick = new Box (Orientation.HORIZONTAL, 6);
            quick.homogeneous = true;
            var today = new DateTime.now_local ();
            string[] names = { _("Today"), _("Tomorrow"), _("Next Week") };
            int[] offsets = { 0, 1, 7 };
            for (int i = 0; i < names.length; i++) {
                int offset = offsets[i];
                var b = new Button.with_label (names[i]);
                b.add_css_class ("pill");
                b.clicked.connect (() => {
                    pop.popdown ();
                    set_due (today.add_days (offset));
                });
                quick.append (b);
            }
            box.append (quick);
            var cal = new Gtk.Calendar ();
            if (task.due != null) cal.select_day (task.due.to_local ());
            cal.day_selected.connect (() => {
                pop.popdown ();
                set_due (cal.get_date ());
            });
            box.append (cal);
            if (task.due != null) {
                var clear = new Button.with_label (_("Remove Date"));
                clear.add_css_class ("flat");
                clear.clicked.connect (() => {
                    pop.popdown ();
                    set_due (null);
                });
                box.append (clear);
            }
            pop.child = box;
            return pop;
        }

        private void set_due (DateTime? day) {
            if (day == null) {
                task.due = null;
                task.due_has_time = false;
                if (task.reminder_at == null) task.reminder_minutes = -1;
            } else {
                var d = day.to_local ();
                int h = 0, m = 0;
                if (task.due != null && task.due_has_time) {
                    var old = task.due.to_local ();
                    h = old.get_hour ();
                    m = old.get_minute ();
                }
                task.due = new DateTime.local (d.get_year (), d.get_month (), d.get_day_of_month (), h, m, 0);
            }
            task.reminded = 0;
            win.task_edited (task, true);
            Idle.add (() => {
                win.show_task (task);
                return Source.REMOVE;
            });
        }
    }
}
