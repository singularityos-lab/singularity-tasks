using Gtk;

namespace Singularity.Apps.Tasks {

    public class TasksApp : Singularity.Application {
        public TaskStore store = new TaskStore ();
        public Storage storage;
        public OnlineTasks online;
        public string? load_error = null;
        public bool show_completed = true;
        public string last_view = "today";
        public string last_list = "";
        private uint save_source;
        private uint reminder_source;
        private uint tick_source;
        private bool save_failed;
        public GLib.Settings? settings;
        public FocusTimer focus = new FocusTimer ();
        private uint focus_source;
        public signal void focus_changed ();
        private TasksSearch search_provider;
        private bool pending_new_task = false;

        public TasksApp () {
            Object (application_id: "dev.sinty.tasks", flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option ("new-task", 0, OptionFlags.NONE, OptionArg.NONE, _("Start typing a new task"), null);
            search_provider = new TasksSearch (this);
            search_provider.export (this);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("new-task")) return -1;
            try {
                register (null);
            } catch (Error e) {
                warning ("tasks: %s", e.message);
                return 1;
            }
            if (get_is_remote ()) {
                activate_action ("new-task", null);
                return 0;
            }
            pending_new_task = true;
            return -1;
        }

        public Task? quick_add (string text, bool due_today) {
            if (text.strip () == "" || load_error != null) return null;
            var now = new DateTime.now_local ();
            var e = QuickParser.parse (text.strip (), now);
            if (e.title.strip () == "") return null;
            var l = store.list (last_list);
            if (l == null || l.read_only) l = store.ensure_list ();
            var t = store.add_task (l.id, e.title);
            foreach (string tag in e.tags) if (!t.tags.contains (tag)) t.tags.add (tag);
            t.priority = e.priority;
            t.rrule = e.rrule;
            if (e.due != null) {
                t.due = e.due;
                t.due_has_time = e.due_has_time;
            } else if (due_today) {
                t.due = new DateTime.local (now.get_year (), now.get_month (), now.get_day_of_month (), 0, 0, 0);
            }
            schedule_save ();
            store.notify_changed ();
            reschedule_reminders ();
            return t;
        }

        private static string config_path () {
            return Path.build_filename (Environment.get_user_config_dir (), "singularity", "tasks.ini");
        }

        private void load_config () {
            var kf = new KeyFile ();
            try {
                kf.load_from_file (config_path (), KeyFileFlags.NONE);
                show_completed = kf.get_boolean ("tasks", "show-completed");
                last_view = kf.get_string ("tasks", "view");
                last_list = kf.get_string ("tasks", "list");
            } catch (Error e) {
            }
        }

        private void save_config () {
            var kf = new KeyFile ();
            kf.set_boolean ("tasks", "show-completed", show_completed);
            kf.set_string ("tasks", "view", last_view);
            kf.set_string ("tasks", "list", last_list);
            try {
                DirUtils.create_with_parents (Path.get_dirname (config_path ()), 0700);
                kf.save_to_file (config_path ());
            } catch (Error e) {
                warning ("tasks: %s", e.message);
            }
        }

        private uint tasks_bus_id = 0;

        public override bool dbus_register (DBusConnection connection, string object_path) throws Error {
            if (!base.dbus_register (connection, object_path)) return false;
            tasks_bus_id = connection.register_object ("/dev/sinty/tasks/Tasks", new TasksBus (this));
            return true;
        }

        public override void dbus_unregister (DBusConnection connection, string object_path) {
            if (tasks_bus_id != 0) connection.unregister_object (tasks_bus_id);
            tasks_bus_id = 0;
            base.dbus_unregister (connection, object_path);
        }

        protected override void startup () {
            base.startup ();
            IconTheme.get_for_display (Gdk.Display.get_default ()).add_resource_path ("/dev/sinty/tasks/icons");
            var provider = new CssProvider ();
            provider.load_from_string (CSS);
            StyleContext.add_provider_for_display (Gdk.Display.get_default (), provider, STYLE_PROVIDER_PRIORITY_USER + 1);
            load_config ();
            var schemas = SettingsSchemaSource.get_default ();
            if (schemas != null && schemas.lookup ("dev.sinty.tasks", true) != null) {
                settings = new GLib.Settings ("dev.sinty.tasks");
                settings.changed["show-in-calendar"].connect (() => export_calendar ());
            }
            focus.phase_finished.connect (on_focus_finished);
            storage = new Storage (Storage.default_path ());
            try {
                storage.load (store);
            } catch (Error e) {
                load_error = e.message;
            }
            if (load_error == null) export_calendar ();
            online = new OnlineTasks (store);
            try {
                online.load_metadata ();
            } catch (Error e) {
                load_error = e.message;
            }
            online.changed.connect (() => {
                export_calendar ();
                store.notify_changed ();
            });
            online.task_renamed.connect ((old_uid, new_uid) => {
                focus.retarget (old_uid, new_uid);
                withdraw_notification ("task-" + old_uid);
            });
            online.start ();

            var menu = new GLib.Menu ();
            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("New Task"), "win.new-task");
            f1.append (_("New List…"), "win.new-list");
            file.append_section (null, f1);
            var f4 = new GLib.Menu ();
            f4.append (_("Sync Now"), "win.sync-now");
            file.append_section (null, f4);
            var f2 = new GLib.Menu ();
            f2.append (_("Import…"), "win.import");
            f2.append (_("Export List…"), "win.export-list");
            f2.append (_("Export All Lists…"), "win.export-all");
            file.append_section (null, f2);
            var f3 = new GLib.Menu ();
            f3.append (_("Close Window"), "win.close");
            f3.append (_("Quit"), "app.quit");
            file.append_section (null, f3);
            menu.append_submenu (_("File"), file);
            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Find"), "win.find");
            e1.append (_("Move Task to Trash"), "win.delete-task");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Rename List…"), "win.rename-list");
            e2.append (_("Clear Done Tasks"), "win.clear-completed");
            e2.append (_("Delete List…"), "win.delete-list");
            e2.append (_("Empty Trash…"), "win.empty-trash");
            edit.append_section (null, e2);
            var e3 = new GLib.Menu ();
            e3.append (_("Start Focus Timer"), "win.focus-task");
            e3.append (_("Pause or Resume Focus Timer"), "app.focus-pause");
            e3.append (_("Stop Focus Timer"), "app.focus-stop");
            edit.append_section (null, e3);
            var e4 = new GLib.Menu ();
            e4.append (_("Settings"), "app.settings");
            edit.append_section (null, e4);
            menu.append_submenu (_("Edit"), edit);
            var view = new GLib.Menu ();
            var v1 = new GLib.Menu ();
            v1.append (_("Today"), "win.view-today");
            v1.append (_("Upcoming"), "win.view-upcoming");
            v1.append (_("Trash"), "win.view-trash");
            view.append_section (null, v1);
            var v2 = new GLib.Menu ();
            v2.append (_("Show Done Tasks"), "app.show-completed");
            view.append_section (null, v2);
            menu.append_submenu (_("View"), view);
            set_menubar (menu);

            var quit = new SimpleAction ("quit", null);
            quit.activate.connect (() => {
                foreach (var w in get_windows ()) w.close ();
            });
            add_action (quit);
            var completed = new SimpleAction.stateful ("show-completed", null, new Variant.boolean (show_completed));
            completed.activate.connect (() => {
                show_completed = !show_completed;
                completed.set_state (new Variant.boolean (show_completed));
                save_config ();
                store.notify_changed ();
            });
            add_action (completed);
            var show_task = new SimpleAction ("show-task", VariantType.STRING);
            show_task.activate.connect ((p) => {
                activate ();
                var w = get_active_window () as TasksWindow;
                if (w != null) w.reveal_task (p.get_string ());
            });
            add_action (show_task);
            var new_task = new SimpleAction ("new-task", null);
            new_task.activate.connect (() => {
                activate ();
                var w = get_active_window () as TasksWindow;
                if (w != null) w.focus_add ();
            });
            add_action (new_task);
            var show_today = new SimpleAction ("show-today", null);
            show_today.activate.connect (() => {
                activate ();
                var w = get_active_window ();
                if (w != null) w.activate_action ("win.view-today", null);
            });
            add_action (show_today);
            var add_task = new SimpleAction ("add-task", VariantType.STRING);
            add_task.activate.connect ((p) => quick_add (p.get_string (), false));
            add_action (add_task);
            var add_today = new SimpleAction ("add-task-today", VariantType.STRING);
            add_today.activate.connect ((p) => quick_add (p.get_string (), true));
            add_action (add_today);
            var add_linked = new SimpleAction ("add-linked-task", new VariantType ("(ss)"));
            add_linked.activate.connect ((p) => {
                string uid = p.get_child_value (0).get_string ();
                if (uid == "" || store.find (uid) != null) return;
                var t = quick_add (p.get_child_value (1).get_string (), false);
                if (t != null) t.uid = uid;
            });
            add_action (add_linked);
            var set_completed = new SimpleAction ("set-task-completed", new VariantType ("(sb)"));
            set_completed.activate.connect ((p) => {
                var t = store.find (p.get_child_value (0).get_string ());
                bool done = p.get_child_value (1).get_boolean ();
                if (t == null || t.completed == done) return;
                store.set_completed (t, done, new DateTime.now_utc ());
                schedule_save ();
                store.notify_changed ();
                if (done) withdraw_notification ("task-" + t.uid);
            });
            add_action (set_completed);
            var complete = new SimpleAction ("complete-task", VariantType.STRING);
            complete.activate.connect ((p) => {
                var t = store.find (p.get_string ());
                if (t == null) return;
                store.set_completed (t, true, new DateTime.now_utc ());
                schedule_save ();
                store.notify_changed ();
                withdraw_notification ("task-" + t.uid);
            });
            add_action (complete);
            var settings_action = new SimpleAction ("settings", null);
            settings_action.activate.connect (() => {
                try {
                    Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                    shell.open_app_settings ("dev.sinty.tasks");
                } catch (Error e) {
                    warning ("tasks: %s", e.message);
                }
            });
            add_action (settings_action);
            var focus_task = new SimpleAction ("focus-task", VariantType.STRING);
            focus_task.activate.connect ((p) => {
                var t = store.find (p.get_string ());
                if (t != null && !t.trashed) start_focus (t);
            });
            add_action (focus_task);
            var focus_pause = new SimpleAction ("focus-pause", null);
            focus_pause.activate.connect (() => toggle_focus_pause ());
            add_action (focus_pause);
            var focus_stop = new SimpleAction ("focus-stop", null);
            focus_stop.activate.connect (() => stop_focus ());
            add_action (focus_stop);
            focus_pause.set_enabled (focus.running);
            focus_stop.set_enabled (focus.running);
            focus_changed.connect (() => {
                focus_pause.set_enabled (focus.running);
                focus_stop.set_enabled (focus.running);
            });

            set_accels_for_action ("app.quit", { "<Control>q" });
            set_accels_for_action ("win.new-task", { "<Control>n" });
            set_accels_for_action ("win.new-list", { "<Control><Shift>n" });
            set_accels_for_action ("win.import", { "<Control>o" });
            set_accels_for_action ("win.export-list", { "<Control>e" });
            set_accels_for_action ("win.export-all", { "<Control><Shift>e" });
            set_accels_for_action ("win.find", { "<Control>f" });
            set_accels_for_action ("win.rename-list", { "F2" });
            set_accels_for_action ("win.view-today", { "<Control>1" });
            set_accels_for_action ("win.view-upcoming", { "<Control>2" });
            set_accels_for_action ("win.view-trash", { "<Control>3" });
            set_accels_for_action ("app.show-completed", { "<Control>h" });
            set_accels_for_action ("app.settings", { "<Control>comma" });
            set_accels_for_action ("win.focus-task", { "<Control>t" });
            set_accels_for_action ("app.focus-pause", { "<Control>p" });
            set_accels_for_action ("app.focus-stop", { "<Control><Shift>t" });
            set_accels_for_action ("win.close", { "<Control>w" });
            set_accels_for_action ("win.sync-now", { "<Control>r" });

            store.changed.connect (() => reschedule_reminders ());
            tick_source = Timeout.add_seconds (60, () => {
                check_reminders ();
                return Source.CONTINUE;
            });
            reschedule_reminders ();
            check_reminders ();
        }

        protected override void shutdown () {
            if (focus.running) focus.stop (now_seconds ());
            flush ();
            save_config ();
            if (tick_source != 0) Source.remove (tick_source);
            if (reminder_source != 0) Source.remove (reminder_source);
            base.shutdown ();
        }

        public override void activate () {
            var w = get_active_window ();
            if (w == null) w = new TasksWindow (this);
            w.present ();
            if (pending_new_task) {
                pending_new_task = false;
                ((TasksWindow) w).focus_add ();
            }
        }

        public override void open (File[] files, string hint) {
            activate ();
            var w = get_active_window () as TasksWindow;
            if (w == null) return;
            foreach (var f in files) w.import_ics.begin (f);
        }

        public void schedule_save () {
            if (save_source != 0) Source.remove (save_source);
            save_source = Timeout.add (400, () => {
                save_source = 0;
                flush ();
                return Source.REMOVE;
            });
        }

        public void flush () {
            if (save_source != 0) {
                Source.remove (save_source);
                save_source = 0;
            }
            if (online != null) online.push ();
            if (load_error != null && store.tasks.size == 0 && store.lists.size == 0) return;
            try {
                online.save_metadata ();
                storage.save (store);
                save_failed = false;
                export_calendar ();
            } catch (Error e) {
                warning ("tasks: %s", e.message);
                if (save_failed) return;
                save_failed = true;
                var w = get_active_window () as TasksWindow;
                if (w != null) w.show_error (_("Your Tasks Could Not Be Saved"), e.message);
            }
        }

        public void export_calendar () {
            bool enabled = settings == null || settings.get_boolean ("show-in-calendar");
            try {
                CalendarFeed.write (store, CalendarFeed.calendar_dir (), enabled);
            } catch (Error e) {
                warning ("tasks: %s", e.message);
            }
        }

        public static int64 now_seconds () {
            return get_real_time () / 1000000;
        }

        public void start_focus (Task t) {
            int64 now = now_seconds ();
            if (focus.running) focus.stop (now);
            focus.focus_length = (settings != null ? settings.get_int ("focus-minutes") : 25) * 60;
            focus.break_length = (settings != null ? settings.get_int ("break-minutes") : 5) * 60;
            focus.start (t.uid, now);
            withdraw_notification ("focus");
            ensure_focus_tick ();
            focus_changed ();
        }

        public void toggle_focus_pause () {
            if (!focus.running) return;
            int64 now = now_seconds ();
            if (focus.paused) focus.resume (now);
            else focus.pause (now);
            focus_changed ();
        }

        public void stop_focus () {
            if (!focus.running) return;
            focus.stop (now_seconds ());
            focus_changed ();
        }

        private void ensure_focus_tick () {
            if (focus_source != 0) return;
            focus_source = Timeout.add (500, () => {
                focus.tick (now_seconds ());
                focus_changed ();
                if (focus.running) return Source.CONTINUE;
                focus_source = 0;
                return Source.REMOVE;
            });
        }

        private void on_focus_finished (FocusPhase finished, string uid, int64 seconds) {
            var t = store.find (uid);
            if (t != null && seconds > 0) {
                t.focus_seconds += seconds;
                schedule_save ();
                store.notify_changed ();
            }
            string title = t != null && t.title != "" ? t.title : _("Untitled Task");
            if (finished == FocusPhase.FOCUS) {
                var n = new GLib.Notification (_("Focus Session Done"));
                int minutes = focus.break_length / 60;
                n.set_body (ngettext ("%s. Time for a %d minute break.", "%s. Time for a %d minute break.", minutes).printf (title, minutes));
                n.set_icon (new ThemedIcon ("dev.sinty.tasks"));
                n.set_default_action_and_target_value ("app.show-task", new Variant.string (uid));
                if (t != null && !t.trashed && !t.completed) n.add_button_with_target_value (_("Mark Done"), "app.complete-task", new Variant.string (uid));
                n.add_button (_("Skip Break"), "app.focus-stop");
                send_notification ("focus", n);
            } else if (finished == FocusPhase.BREAK) {
                var n = new GLib.Notification (_("Break Is Over"));
                n.set_body (_("Ready for another focus session on %s?").printf (title));
                n.set_icon (new ThemedIcon ("dev.sinty.tasks"));
                n.set_default_action_and_target_value ("app.show-task", new Variant.string (uid));
                if (t != null && !t.trashed && !t.completed) n.add_button_with_target_value (_("Focus Again"), "app.focus-task", new Variant.string (uid));
                send_notification ("focus", n);
            }
        }

        public void reschedule_reminders () {
            if (reminder_source != 0) Source.remove (reminder_source);
            reminder_source = 0;
            var now = new DateTime.now_local ();
            var next = store.next_reminder (now);
            if (next == null) return;
            int64 wait = next.to_unix () - now.to_unix ();
            if (wait > 3600) return;
            reminder_source = Timeout.add_seconds ((uint) int64.max (1, wait), () => {
                reminder_source = 0;
                check_reminders ();
                reschedule_reminders ();
                return Source.REMOVE;
            });
        }

        private void check_reminders () {
            var now = new DateTime.now_local ();
            var due = store.due_reminders (now);
            if (due.size == 0) return;
            foreach (var t in due) {
                var n = new GLib.Notification (t.title != "" ? t.title : _("Task Reminder"));
                string body = t.due != null ? _("Due %s").printf (TaskFormat.due (t, now)) : "";
                if (t.notes.strip () != "") {
                    string first = t.notes.strip ().split ("\n")[0];
                    body = body != "" ? body + "\n" + first : first;
                }
                if (body != "") n.set_body (body);
                n.set_icon (new ThemedIcon ("dev.sinty.tasks"));
                n.set_default_action_and_target_value ("app.show-task", new Variant.string (t.uid));
                n.add_button_with_target_value (_("Mark as Done"), "app.complete-task", new Variant.string (t.uid));
                send_notification ("task-" + t.uid, n);
                t.reminded = t.reminder_time ().to_unix ();
            }
            schedule_save ();
        }

        private const string CSS = """
.tasks-list {
    background: transparent;
    padding: 0 16px 24px 16px;
}

.tasks-list > row {
    border-radius: 12px;
    padding: 7px 8px;
    margin: 1px 0;
}

.tasks-list > row:selected {
    background-color: alpha(@accent_bg_color, 0.14);
    color: inherit;
}

.tasks-row-done .tasks-title {
    text-decoration: line-through;
    opacity: 0.55;
}

.tasks-title {
    font-weight: 500;
}

.tasks-meta {
    font-size: 12px;
    opacity: 0.65;
}

.tasks-overdue {
    color: @error_color;
    opacity: 1;
    font-weight: 600;
}

.tasks-due-today {
    color: @accent_color;
    opacity: 1;
    font-weight: 600;
}

.tasks-tag {
    font-size: 11px;
    padding: 0 7px;
    border-radius: 99px;
    background-color: alpha(@accent_bg_color, 0.14);
}

.tasks-count {
    font-size: 12px;
    font-feature-settings: "tnum";
    opacity: 0.55;
}

.tasks-progress {
    color: @accent_bg_color;
}

.tasks-priority-high {
    color: #e01b24;
}

.tasks-priority-medium {
    color: #e5a50a;
}

.tasks-priority-low {
    color: #3584e4;
}

.tasks-expander {
    min-width: 24px;
    min-height: 24px;
    padding: 0;
}

.tasks-add {
    border-radius: 12px;
    padding: 4px 10px;
    min-height: 34px;
}

.tasks-drop-before {
    box-shadow: inset 0 2px 0 0 @accent_bg_color;
}

.tasks-drop-after {
    box-shadow: inset 0 -2px 0 0 @accent_bg_color;
}

.tasks-drop-into,
.tasks-drop-list {
    background-color: alpha(@accent_bg_color, 0.2);
}

.tasks-dragging {
    opacity: 0.4;
}

.tasks-panel {
    padding: 18px;
    border-radius: 20px;
    background-color: alpha(@window_fg_color, 0.05);
}

.tasks-panel-heading {
    font-weight: 700;
    font-size: 13px;
    opacity: 0.8;
}

.tasks-detail-title {
    font-size: 17px;
    font-weight: 700;
    background: transparent;
    box-shadow: none;
    border: none;
}

.tasks-notes {
    border-radius: 12px;
    background-color: @view_bg_color;
}

.tasks-notes textview,
.tasks-notes text {
    background: transparent;
}

.tasks-focus {
    margin: 0 24px 10px 24px;
    padding: 10px 14px;
    border-radius: 16px;
    background-color: alpha(@accent_bg_color, 0.12);
}

.tasks-day {
    min-width: 26px;
    min-height: 26px;
    padding: 0;
    font-size: 12px;
}

.tasks-day:checked {
    background-color: @accent_bg_color;
    color: @accent_fg_color;
}

.tasks-focus-time {
    font-feature-settings: "tnum";
}

.tasks-parent-link {
    font-size: 12px;
    padding: 2px 8px;
}
""";
    }

    public static int main (string[] args) {
        Intl.setlocale (LocaleCategory.ALL, "");
        string locale_dir = "/usr/share/locale";
        try {
            string exe = FileUtils.read_link ("/proc/self/exe");
            locale_dir = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "share", "locale");
        } catch (Error e) {
        }
        Intl.bindtextdomain ("singularity-tasks", locale_dir);
        Intl.bind_textdomain_codeset ("singularity-tasks", "UTF-8");
        Intl.textdomain ("singularity-tasks");
        return new TasksApp ().run (args);
    }
}
