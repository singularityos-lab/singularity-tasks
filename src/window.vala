using Gtk;
using Singularity.Widgets;

namespace Singularity.Apps.Tasks {

    public class TasksWindow : Singularity.Widgets.Window {
        private const string TODAY = "today";
        private const string UPCOMING = "upcoming";
        private const string TRASH = "trash";

        private TasksApp app;
        private TaskStore store;
        private AppSidebar sidebar;
        private Stack stack;
        private Stack body;
        private ListBox list;
        private Singularity.Animation.ListAnimator animator;
        private ScrolledWindow scroll;
        private StatusPage empty;
        private Label heading_label;
        private Label subtitle;
        private Box status_box;
        private Label status_label;
        private Button status_button;
        private Entry add_entry;
        private Revealer preview_revealer;
        private ChipBar preview;
        private QuickEntry? parsed;
        private bool skip_dates;
        private bool skip_repeat;
        private bool skip_priority;
        private Gee.HashSet<string> skip_tags = new Gee.HashSet<string> ();
        private Revealer focus_revealer;
        private CircularProgress focus_ring;
        private Label focus_phase;
        private Label focus_title;
        private Label focus_time;
        private Button focus_pause;
        private Revealer panel_revealer;
        private ScrolledWindow panel_scroll;
        private TaskDetail? detail;
        private SearchBubble search;
        private Button add_bubble;
        private Button more_bubble;
        private Button empty_trash_bubble;
        private string view = "";
        private string query = "";
        private uint refresh_source;
        private Gee.HashMap<string, SidebarRow> view_rows = new Gee.HashMap<string, SidebarRow> ();

        public TasksWindow (TasksApp app) {
            Object (application: app);
            this.app = app;
            this.store = app.store;
            set_default_size (1100, 740);
            set_title (_("Tasks"));

            sidebar = new AppSidebar (230);
            set_sidebar (sidebar);

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.add_named (build_welcome (), "welcome");
            stack.add_named (build_main (), "main");
            set_content (stack);

            search = add_bubble_search (_("Search Tasks"), (t) => {
                query = t.strip ();
                refresh ();
            });
            add_bubble = add_bubble_icon ("list-add-symbolic", _("New Task (Ctrl+N)"), () => focus_add ());
            more_bubble = add_bubble_icon ("view-more-symbolic", _("List Options"), () => show_more ());
            empty_trash_bubble = add_bubble_text (_("Empty Trash"), () => confirm_empty_trash ());

            install_actions ();
            store.changed.connect (() => queue_refresh ());
            app.online.task_updated.connect ((t) => {
                if (detail != null && detail.task == t) reload_detail ();
            });
            view = app.last_view;
            refresh ();
            if (app.load_error != null) {
                Idle.add (() => {
                    show_error (_("Your Tasks Could Not Be Read"), app.load_error);
                    app.load_error = null;
                    return Source.REMOVE;
                });
            }
        }

        private Widget build_welcome () {
            var wp = new WelcomePage ();
            wp.app_icon_name = "dev.sinty.tasks";
            wp.title = _("Tasks");
            wp.subtitle = _("Plan what to do today and later, in lists of your own");
            wp.add_action ("text-x-generic", _("New List"), _("Start a list of things to do"), () => new_list ());
            wp.add_action ("text-calendar", _("Import"), _("Tasks from an iCalendar file of another app"), () => import_file ());
            return wp;
        }

        private Widget build_main () {
            var content = new Box (Orientation.HORIZONTAL, 0);
            var main = new Box (Orientation.VERTICAL, 0);
            main.hexpand = true;

            var header = new Box (Orientation.VERTICAL, 2);
            header.margin_start = 28;
            header.margin_end = 28;
            header.margin_top = 16;
            header.margin_bottom = 10;
            apply_view_edge (header);
            heading_label = new Label ("");
            heading_label.xalign = 0;
            heading_label.ellipsize = Pango.EllipsizeMode.END;
            heading_label.add_css_class ("title-2");
            header.append (heading_label);
            subtitle = new Label ("");
            subtitle.xalign = 0;
            subtitle.add_css_class ("dim-label");
            header.append (subtitle);
            status_box = new Box (Orientation.HORIZONTAL, 8);
            status_box.margin_top = 4;
            status_label = new Label ("");
            status_label.xalign = 0;
            status_label.ellipsize = Pango.EllipsizeMode.END;
            status_label.max_width_chars = 90;
            status_label.add_css_class ("caption");
            status_label.add_css_class ("dim-label");
            status_box.append (status_label);
            status_button = new Button ();
            status_button.valign = Align.CENTER;
            status_button.clicked.connect (() => {
                var l = current_list ();
                if (l != null && l.attention) open_accounts ();
                else app.online.sync_now (l);
            });
            status_box.append (status_button);
            status_box.visible = false;
            header.append (status_box);
            main.append (header);

            add_entry = new Entry ();
            add_entry.placeholder_text = _("Add a task, like: Call Anna tomorrow at 5pm #work !high");
            add_entry.primary_icon_name = "list-add-symbolic";
            add_entry.margin_start = 24;
            add_entry.margin_end = 24;
            add_entry.margin_bottom = 8;
            add_entry.add_css_class ("tasks-add");
            add_entry.activate.connect (() => quick_add ());
            add_entry.changed.connect (() => update_preview ());
            main.append (add_entry);

            preview = new ChipBar ();
            preview.ellipsize_labels = false;
            preview.close_tooltip = _("Keep These Words in the Title");
            preview.margin_start = 16;
            preview.margin_end = 16;
            preview.chip_closed.connect ((id) => reject_part (id));
            preview_revealer = new Revealer ();
            preview_revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
            preview_revealer.child = preview;
            main.append (preview_revealer);

            main.append (build_focus_bar ());

            list = new ListBox ();
            animator = new Singularity.Animation.ListAnimator (list);
            list.add_css_class ("tasks-list");
            list.selection_mode = SelectionMode.SINGLE;
            list.row_activated.connect ((row) => {
                var tr = row as TaskRow;
                if (tr != null) show_task (tr.task);
            });
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                var tr = list.get_selected_row () as TaskRow;
                if (tr == null) return false;
                if (keyval == Gdk.Key.Delete || keyval == Gdk.Key.KP_Delete) {
                    if (tr.task.trashed) confirm_purge (tr.task);
                    else trash_task (tr.task);
                    return true;
                }
                if (keyval == Gdk.Key.space && !tr.task.trashed) {
                    set_done (tr.task, !tr.task.completed);
                    return true;
                }
                if (keyval == Gdk.Key.Menu || (keyval == Gdk.Key.F10 && (state & Gdk.ModifierType.SHIFT_MASK) != 0)) {
                    task_menu (tr, 24, tr.get_height () / 2);
                    return true;
                }
                return false;
            });
            list.add_controller (keys);
            scroll = new ScrolledWindow ();
            scroll.hscrollbar_policy = PolicyType.NEVER;
            scroll.vexpand = true;
            scroll.child = list;

            empty = new StatusPage ();
            body = new Stack ();
            body.vexpand = true;
            body.add_named (scroll, "list");
            body.add_named (empty, "empty");
            main.append (body);
            content.append (main);

            panel_scroll = new ScrolledWindow ();
            panel_scroll.hscrollbar_policy = PolicyType.NEVER;
            panel_scroll.vexpand = true;
            panel_scroll.set_size_request (400, -1);
            var outer = new Box (Orientation.VERTICAL, 0);
            outer.margin_end = 16;
            outer.margin_bottom = 16;
            apply_view_edge (outer);
            outer.append (panel_scroll);
            panel_revealer = new Revealer ();
            panel_revealer.transition_type = RevealerTransitionType.SLIDE_LEFT;
            panel_revealer.child = outer;
            panel_revealer.hexpand = false;
            panel_revealer.visible = false;
            panel_revealer.notify["child-revealed"].connect (() => {
                if (!panel_revealer.reveal_child && !panel_revealer.child_revealed) {
                    panel_revealer.visible = false;
                    panel_scroll.child = null;
                    detail = null;
                }
            });
            content.append (panel_revealer);
            return content;
        }

        private bool is_list_view () {
            return view.has_prefix ("list:");
        }

        private string view_list_id () {
            return is_list_view () ? view.substring (5) : "";
        }

        private TaskList? current_list () {
            return is_list_view () ? store.list (view_list_id ()) : null;
        }

        private TaskList target_list () {
            var l = current_list ();
            if (l != null && !l.read_only) return l;
            var remembered = store.list (app.last_list);
            return remembered != null && !remembered.read_only ? remembered : store.ensure_list ();
        }

        public void select_view (string id) {
            view = id;
            app.last_view = id;
            if (is_list_view ()) app.last_list = view_list_id ();
            if (query != "") search.clear ();
            refresh ();
            if (is_list_view ()) add_entry.grab_focus ();
        }

        private void queue_refresh () {
            if (refresh_source != 0) return;
            refresh_source = Idle.add (() => {
                refresh_source = 0;
                refresh ();
                return Source.REMOVE;
            });
        }

        public void refresh () {
            if (refresh_source != 0) {
                Source.remove (refresh_source);
                refresh_source = 0;
            }
            bool nothing = store.lists.size == 0 && store.tasks.size == 0;
            stack.visible_child_name = nothing ? "welcome" : "main";
            set_sidebar_visible (!nothing);
            if (!nothing && view != TODAY && view != UPCOMING && view != TRASH && current_list () == null) {
                view = store.lists.size > 0 ? "list:" + store.lists[0].id : TODAY;
            }
            rebuild_sidebar ();
            animator.rebuild (rebuild_list);
            sync_bubbles ();
            if (detail != null) {
                var t = detail.task;
                if (!store.tasks.contains (t)) close_detail ();
            }
        }

        private void rebuild_sidebar () {
            Widget? child;
            while ((child = sidebar.box.get_first_child ()) != null) sidebar.box.remove (child);
            view_rows.clear ();
            var now = new DateTime.now_local ();
            add_view_row (TODAY, "x-office-calendar-symbolic", _("Today"), store.today (now).size);
            add_view_row (UPCOMING, "alarm-symbolic", _("Upcoming"), store.upcoming (now).size);
            sidebar.box.append (new SidebarSectionLabel (_("Lists")));
            string group = "";
            foreach (var l in store.lists) {
                if (l.online) continue;
                add_list_row (l);
            }
            var add = new SidebarRow ("list-add-symbolic", _("New List"));
            add.add_css_class ("tasks-new-list");
            add.clicked.connect (() => new_list ());
            sidebar.box.append (add);
            foreach (var l in store.lists) {
                if (!l.online) continue;
                if (l.account_id != group) {
                    group = l.account_id;
                    sidebar.box.append (new SidebarSectionLabel (l.account_name));
                }
                add_list_row (l);
            }
            var spacer = new Box (Orientation.VERTICAL, 0);
            spacer.vexpand = true;
            sidebar.box.append (spacer);
            add_view_row (TRASH, "user-trash-symbolic", _("Trash"), store.count_trashed ());
            foreach (var e in view_rows.entries) e.value.set_active (query == "" && e.key == view);
        }

        private void add_list_row (TaskList l) {
            var row = add_view_row ("list:" + l.id, l.icon_name, l.name, store.count_open (l.id));
            if (l.online) {
                if (l.status != "") {
                    var warn = new Image.from_icon_name (l.offline ? "network-offline-symbolic" : "dialog-warning-symbolic");
                    warn.pixel_size = 16;
                    warn.add_css_class ("dim-label");
                    var inner = row.get_child () as Box;
                    if (inner != null) inner.append (warn);
                }
                row.tooltip_text = l.status != "" ? "%s\n%s".printf (l.account_name, l.status) : l.account_name;
            }
            var target = l;
            var drop = new DropTarget (typeof (string), Gdk.DragAction.MOVE);
            drop.enter.connect ((x, y) => {
                if (target.read_only) return (Gdk.DragAction) 0;
                row.add_css_class ("tasks-drop-list");
                return Gdk.DragAction.MOVE;
            });
            drop.leave.connect (() => row.remove_css_class ("tasks-drop-list"));
            drop.drop.connect ((value, x, y) => {
                row.remove_css_class ("tasks-drop-list");
                string? uid = value.get_string ();
                var t = uid != null ? store.find (uid) : null;
                if (t == null || t.trashed || target.read_only || store.is_read_only (t)) return false;
                move_to_list (t, target);
                return true;
            });
            row.add_controller (drop);
            var click = new GestureClick ();
            click.button = 3;
            click.pressed.connect ((n, x, y) => list_menu (row, target, x, y));
            row.add_controller (click);
        }

        private SidebarRow add_view_row (string id, string icon, string text, int count) {
            var row = new SidebarRow (icon, text);
            if (count > 0) {
                var badge = new Label (count.to_string ());
                badge.add_css_class ("tasks-count");
                var inner = row.get_child () as Box;
                if (inner != null) inner.append (badge);
            }
            row.clicked.connect (() => select_view (id));
            view_rows[id] = row;
            sidebar.box.append (row);
            return row;
        }

        private void rebuild_list () {
            Task? keep = null;
            var sel = list.get_selected_row () as TaskRow;
            if (sel != null) keep = sel.task;
            double scroll_pos = scroll.vadjustment.value;
            Widget? child;
            while ((child = list.get_first_child ()) != null) list.remove (child);
            var now = new DateTime.now_local ();
            bool tree = false;
            bool context = true;
            var items = new Gee.ArrayList<Task> ();
            var depths = new Gee.HashMap<Task, int> ();
            string heading;
            string sub = "";
            if (query != "") {
                heading = _("Search");
                items.add_all (store.search (query));
                sub = ngettext ("%d task found", "%d tasks found", items.size).printf (items.size);
            } else if (view == TODAY) {
                heading = _("Today");
                items.add_all (store.today (now));
                sub = now.format ("%A %-d %B");
            } else if (view == UPCOMING) {
                heading = _("Upcoming");
                items.add_all (store.upcoming (now));
                sub = ngettext ("%d task coming up", "%d tasks coming up", items.size).printf (items.size);
            } else if (view == TRASH) {
                heading = _("Trash");
                items.add_all (store.trashed_roots ());
                sub = items.size > 0 ? _("Deleted tasks stay here until the trash is emptied") : "";
            } else {
                var l = current_list ();
                heading = l != null ? l.name : "";
                tree = true;
                context = false;
                if (l != null) {
                    collect_tree (l.id, "", 0, items, depths);
                    int open = store.count_open (l.id);
                    int done = 0;
                    foreach (var t in store.tasks) if (t.list_id == l.id && !t.trashed && t.completed) done++;
                    sub = done > 0 ? _("%d to do, %d done").printf (open, done) : ngettext ("%d to do", "%d to do", open).printf (open);
                    if (done > 0 && !app.show_completed) sub += ", " + _("done tasks hidden");
                }
            }
            heading_label.label = heading;
            subtitle.label = sub;
            subtitle.visible = sub != "";
            var shown = query == "" ? current_list () : null;
            add_entry.visible = query == "" && view != TRASH && (shown == null || !shown.read_only);
            update_status (shown);
            TaskRow? select = null;
            foreach (var t in items) {
                var row = new TaskRow (this, store, t, tree ? depths[t] : 0, tree, context, now);
                list.append (row);
                if (t == keep) select = row;
            }
            if (items.size == 0) {
                fill_empty ();
            } else {
                body.visible_child_name = "list";
            }
            if (select != null) list.select_row (select);
            Idle.add (() => {
                scroll.vadjustment.value = scroll_pos;
                return Source.REMOVE;
            });
        }

        private void update_status (TaskList? l) {
            string text = "";
            if (l != null && l.online) {
                text = l.status;
                if (l.read_only) text = text != "" ? _("Read only, %s").printf (text) : _("Read only");
            }
            status_label.label = text;
            status_box.visible = l != null && l.online;
            if (l == null || !l.online) return;
            bool reauth = l.attention;
            status_label.label = text != "" ? text : _("Synced with %s").printf (l.account_name);
            status_label.tooltip_text = status_label.label;
            status_button.label = reauth ? _("Open Settings") : (app.online.syncing (l) ? _("Syncing…") : _("Sync Now"));
            status_button.sensitive = reauth || !app.online.syncing (l);
        }

        private void open_accounts () {
            try {
                Singularity.Shell.ShellService shell = Bus.get_proxy_sync (BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                shell.open_settings ("accounts");
            } catch (Error e) {
                show_error (_("Settings Are Not Available"), e.message);
            }
        }

        private void collect_tree (string list_id, string parent_uid, int depth, Gee.ArrayList<Task> into, Gee.HashMap<Task, int> depths) {
            foreach (var t in store.children (list_id, parent_uid)) {
                if (t.completed && !app.show_completed) continue;
                into.add (t);
                depths[t] = depth;
                if (t.expanded) collect_tree (list_id, t.uid, depth + 1, into, depths);
            }
        }

        private void fill_empty () {
            if (query != "") {
                empty.icon_name = "system-search";
                empty.title = _("No Matching Tasks");
                empty.description = _("Try other words, or #tag to find tasks with a tag.");
                var clear = new Button.with_label (_("Clear Search"));
                clear.add_css_class ("pill");
                clear.add_css_class ("suggested-action");
                clear.halign = Align.CENTER;
                clear.clicked.connect (() => search.clear ());
                empty.child = clear;
                body.visible_child_name = "empty";
                return;
            }
            var old = body.get_child_by_name ("none");
            if (old != null) body.remove (old);
            var page = new WelcomePage ();
            page.is_section = true;
            page.app_icon_name = "dev.sinty.tasks";
            if (view == TODAY) {
                page.title = _("Nothing Due Today");
                page.subtitle = _("Tasks due today or earlier show up here.");
                page.add_action ("document-new", _("New Task"), _("Write it down, with a date such as today or friday"), () => focus_add ());
                page.add_action ("x-office-calendar", _("Upcoming"), _("Tasks with a due date after today"), () => select_view (UPCOMING));
            } else if (view == UPCOMING) {
                page.title = _("Nothing Coming Up");
                page.subtitle = _("Tasks with a due date after today show up here.");
                page.add_action ("document-new", _("New Task"), _("Write it down, with a date such as tomorrow or next week"), () => focus_add ());
                page.add_action ("x-office-calendar", _("Today"), _("Tasks due today or earlier"), () => select_view (TODAY));
            } else if (view == TRASH) {
                page.app_icon_name = "user-trash";
                page.title = _("Trash Is Empty");
                page.subtitle = _("Deleted tasks are kept here until you empty the trash.");
                page.add_action ("x-office-calendar", _("Today"), _("Tasks due today or earlier"), () => select_view (TODAY));
            } else {
                var l = current_list ();
                bool hidden = false;
                if (l != null) foreach (var t in store.tasks) if (t.list_id == l.id && !t.trashed && t.completed) hidden = true;
                if (hidden) {
                    page.title = _("All Done");
                    page.subtitle = _("Every task in this list is done.");
                    page.add_action ("text-x-generic", _("Show Done Tasks"), _("See what you finished in this list"), () => app.activate_action ("show-completed", null));
                    page.add_action ("document-new", _("New Task"), _("Add another one to this list"), () => focus_add ());
                } else {
                    page.title = _("No Tasks");
                    page.subtitle = _("Nothing to do in this list yet.");
                    page.add_action ("document-new", _("New Task"), _("Write it down, with a date such as today or friday"), () => focus_add ());
                    page.add_action ("text-calendar", _("Import"), _("Tasks from an iCalendar file of another app"), () => import_file ());
                }
            }
            body.add_named (page, "none");
            body.visible_child_name = "none";
        }

        private void sync_bubbles () {
            bool main = stack.visible_child_name == "main";
            search.visible = main;
            add_bubble.visible = main && view != TRASH;
            more_bubble.visible = main && is_list_view () && query == "";
            empty_trash_bubble.visible = main && view == TRASH && query == "" && store.count_trashed () > 0;
            sync_actions ();
        }

        private void set_action_enabled (string name, bool enabled) {
            var a = lookup_action (name) as SimpleAction;
            if (a != null) a.set_enabled (enabled);
        }

        private void sync_actions () {
            bool main = stack.visible_child_name == "main";
            bool has_list = current_list () != null;
            var tr = list.get_selected_row () as TaskRow;
            set_action_enabled ("find", main);
            set_action_enabled ("export-list", has_list);
            set_action_enabled ("export-all", store.lists.size > 0);
            bool local_list = has_list && !current_list ().online;
            bool online = false;
            foreach (var l in store.lists) if (l.online) online = true;
            set_action_enabled ("rename-list", local_list);
            set_action_enabled ("delete-list", local_list);
            set_action_enabled ("sync-now", online);
            set_action_enabled ("clear-completed", has_list);
            set_action_enabled ("delete-task", main && tr != null && !tr.task.trashed && !store.is_read_only (tr.task));
            set_action_enabled ("focus-task", main && ((tr != null && !tr.task.trashed) || (detail != null && panel_revealer.reveal_child)));
            set_action_enabled ("view-today", main);
            set_action_enabled ("view-upcoming", main);
            set_action_enabled ("view-trash", main);
            set_action_enabled ("empty-trash", main && store.count_trashed () > 0);
        }

        public void focus_add () {
            if (store.lists.size == 0) {
                new_list ();
                return;
            }
            if (query != "") search.clear ();
            if (view == TRASH) select_view ("list:" + target_list ().id);
            add_entry.grab_focus ();
        }

        public void focus_search () {
            if (stack.visible_child_name == "main") search.grab_focus_entry ();
        }

        private QuickEntry parse_entry () {
            return QuickParser.parse_with (add_entry.text, new DateTime.now_local (), !skip_dates, !skip_repeat, !skip_priority, skip_tags);
        }

        private void update_preview () {
            if (add_entry.text.strip () == "") {
                skip_dates = skip_repeat = skip_priority = false;
                skip_tags.clear ();
            }
            parsed = add_entry.text.strip () != "" ? parse_entry () : null;
            var stale = new Gee.ArrayList<string> ();
            collect_chips (preview, stale);
            foreach (string id in stale) preview.remove_chip (id);
            if (parsed == null || !parsed.understood ()) {
                preview_revealer.reveal_child = false;
                return;
            }
            var now = new DateTime.now_local ();
            if (parsed.due != null) {
                var probe = new Task ();
                probe.due = parsed.due;
                probe.due_has_time = parsed.due_has_time;
                add_chip ("due", _("Due %s").printf (TaskFormat.due (probe, now)), "x-office-calendar-symbolic");
            }
            if (parsed.rrule != "") add_chip ("repeat", RepeatRule.describe_text (parsed.rrule), "media-playlist-repeat-symbolic");
            if (parsed.priority != Priority.NONE) add_chip ("priority", _("%s Priority").printf (parsed.priority.label ()), "tasks-priority-symbolic");
            foreach (string tag in parsed.tags) add_chip ("tag:" + tag, "#" + tag, "tasks-tag-symbolic");
            add_chip ("title", parsed.title, "document-edit-symbolic");
            preview.set_chip_closable ("title", false);
            preview_revealer.reveal_child = true;
        }

        private void collect_chips (Widget w, Gee.ArrayList<string> into) {
            for (var c = w.get_first_child (); c != null; c = c.get_next_sibling ()) {
                var chip = c as Chip;
                if (chip != null) into.add (chip.chip_id);
                else collect_chips (c, into);
            }
        }

        private void add_chip (string id, string label, string icon) {
            preview.add_chip (id, label);
            preview.set_chip_closable (id, true);
            var img = new Image.from_icon_name (icon);
            img.pixel_size = 14;
            preview.set_chip_prefix (id, img);
            var chip = preview.get_chip_widget (id);
            if (chip != null && id != "title") chip.tooltip_text = _("Understood from what you typed");
            if (chip != null && id == "title") chip.tooltip_text = _("Title of the new task");
        }

        private void reject_part (string id) {
            if (id == "due") skip_dates = true;
            else if (id == "repeat") skip_repeat = true;
            else if (id == "priority") skip_priority = true;
            else if (id.has_prefix ("tag:")) skip_tags.add (id.substring (4));
            update_preview ();
            add_entry.grab_focus_without_selecting ();
        }

        private void quick_add () {
            string text = add_entry.text.strip ();
            if (text == "") return;
            var e = parse_entry ();
            var l = target_list ();
            var t = store.add_task (l.id, e.title);
            foreach (string tag in e.tags) if (!t.tags.contains (tag)) t.tags.add (tag);
            t.priority = e.priority;
            t.rrule = e.rrule;
            var today = new DateTime.now_local ();
            if (e.due != null) {
                t.due = e.due;
                t.due_has_time = e.due_has_time;
            } else if (view == TODAY) {
                t.due = new DateTime.local (today.get_year (), today.get_month (), today.get_day_of_month (), 0, 0, 0);
            } else if (view == UPCOMING) {
                t.due = new DateTime.local (today.get_year (), today.get_month (), today.get_day_of_month (), 0, 0, 0).add_days (1);
            }
            add_entry.text = "";
            changed_now ();
            app.reschedule_reminders ();
        }

        private Widget build_focus_bar () {
            var bar = new Box (Orientation.HORIZONTAL, 12);
            bar.add_css_class ("tasks-focus");
            focus_ring = new CircularProgress (36);
            focus_ring.add_css_class ("tasks-progress");
            focus_ring.valign = Align.CENTER;
            bar.append (focus_ring);
            var texts = new Box (Orientation.VERTICAL, 0);
            texts.hexpand = true;
            texts.valign = Align.CENTER;
            focus_phase = new Label ("");
            focus_phase.xalign = 0;
            focus_phase.add_css_class ("caption");
            focus_phase.add_css_class ("dim-label");
            texts.append (focus_phase);
            focus_title = new Label ("");
            focus_title.xalign = 0;
            focus_title.ellipsize = Pango.EllipsizeMode.END;
            focus_title.add_css_class ("heading");
            texts.append (focus_title);
            bar.append (texts);
            focus_time = new Label ("");
            focus_time.add_css_class ("title-2");
            focus_time.add_css_class ("tasks-focus-time");
            focus_time.valign = Align.CENTER;
            bar.append (focus_time);
            focus_pause = new Button.from_icon_name ("media-playback-pause-symbolic");
            focus_pause.add_css_class ("flat");
            focus_pause.add_css_class ("circular");
            focus_pause.valign = Align.CENTER;
            focus_pause.clicked.connect (() => app.toggle_focus_pause ());
            bar.append (focus_pause);
            var stop = new Button.from_icon_name ("media-playback-stop-symbolic");
            stop.add_css_class ("flat");
            stop.add_css_class ("circular");
            stop.valign = Align.CENTER;
            stop.tooltip_text = _("Stop Focus Timer (Ctrl+Shift+T)");
            stop.clicked.connect (() => app.stop_focus ());
            bar.append (stop);
            var click = new GestureClick ();
            click.released.connect (() => {
                var t = store.find (app.focus.task_uid);
                if (t != null) show_task (t);
            });
            texts.add_controller (click);
            focus_revealer = new Revealer ();
            focus_revealer.transition_type = RevealerTransitionType.SLIDE_DOWN;
            focus_revealer.child = bar;
            app.focus_changed.connect (() => {
                bool was = focus_revealer.reveal_child;
                sync_focus ();
                if (was != focus_revealer.reveal_child) reload_detail ();
            });
            sync_focus ();
            return focus_revealer;
        }

        private void sync_focus () {
            var f = app.focus;
            focus_revealer.reveal_child = f.running;
            if (!f.running) return;
            int64 now = TasksApp.now_seconds ();
            var t = store.find (f.task_uid);
            focus_title.label = t != null && t.title != "" ? t.title : _("Untitled Task");
            string phase = f.phase == FocusPhase.FOCUS ? _("Focus") : _("Break");
            focus_phase.label = f.paused ? _("%s, paused").printf (phase) : phase;
            focus_time.label = FocusTimer.clock (f.remaining (now));
            focus_ring.fraction = f.fraction (now);
            focus_pause.icon_name = f.paused ? "media-playback-start-symbolic" : "media-playback-pause-symbolic";
            focus_pause.tooltip_text = f.paused ? _("Resume (Ctrl+P)") : _("Pause (Ctrl+P)");
        }

        public string focus_task_uid () {
            return app.focus.running ? app.focus.task_uid : "";
        }

        public void stop_focus () {
            app.stop_focus ();
            reload_detail ();
        }

        public void focus_on (Task t) {
            if (t.trashed) return;
            app.start_focus (t);
            if (detail != null && detail.task == t) reload_detail ();
        }

        private void changed_now () {
            app.schedule_save ();
            store.notify_changed ();
        }

        public void task_edited (Task t, bool structural) {
            t.modified = new DateTime.now_utc ();
            app.schedule_save ();
            app.reschedule_reminders ();
            if (structural) {
                store.notify_changed ();
                return;
            }
            if (refresh_source != 0) Source.remove (refresh_source);
            refresh_source = Timeout.add (400, () => {
                refresh_source = 0;
                refresh ();
                return Source.REMOVE;
            });
        }

        public void set_done (Task t, bool done) {
            store.set_completed (t, done, new DateTime.now_utc ());
            changed_now ();
            if (detail != null && (detail.task == t || store.is_ancestor (t, detail.task) || store.is_ancestor (detail.task, t))) reload_detail ();
        }

        public void toggle_expanded (Task t) {
            t.expanded = !t.expanded;
            changed_now ();
        }

        public void show_task (Task t) {
            detail = new TaskDetail (this, store, t);
            panel_scroll.child = detail;
            panel_revealer.visible = true;
            panel_revealer.reveal_child = true;
        }

        private void reload_detail () {
            if (detail == null) return;
            var t = detail.task;
            Idle.add (() => {
                if (detail != null && detail.task == t && store.tasks.contains (t)) show_task (t);
                return Source.REMOVE;
            });
        }

        public void close_detail () {
            panel_revealer.reveal_child = false;
        }

        public void add_subtask (Task parent, string text) {
            if (store.is_read_only (parent)) return;
            var t = store.add_task (parent.list_id, text, parent.uid);
            if (parent.completed) store.set_completed (parent, false, new DateTime.now_utc ());
            parent.expanded = true;
            t.modified = new DateTime.now_utc ();
            changed_now ();
            reload_detail ();
        }

        public void move_to_list (Task t, TaskList l) {
            if (store.move_to_list (t, l.id)) {
                changed_now ();
                reload_detail ();
            }
        }

        public bool drop_task (string uid, Task target, DropPlace place) {
            var t = store.find (uid);
            if (t == null || t == target || t.trashed || store.is_read_only (t) || store.is_read_only (target)) return false;
            bool ok;
            if (place == DropPlace.INTO) {
                ok = store.move (t, target.list_id, target.uid, int.MAX);
                if (ok) target.expanded = true;
            } else {
                ok = store.move_next_to (t, target, place == DropPlace.AFTER);
            }
            if (ok) {
                changed_now ();
                reload_detail ();
            }
            return ok;
        }

        public void trash_task (Task t) {
            if (store.is_read_only (t)) return;
            var l = store.list (t.list_id);
            if (l != null && l.online) {
                var dlg = new ConfirmDialog (app, _("Delete %s?").printf (t.title != "" ? t.title : _("This Task")), "user-trash-symbolic",
                    _("The task and its subtasks are deleted from %s and cannot be restored.").printf (l.account_name), _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
                dlg.transient_for = this;
                dlg.modal = true;
                dlg.response.connect ((r) => {
                    if (r != ConfirmDialog.Response.PRIMARY) return;
                    discard_task (t);
                });
                dlg.present ();
                return;
            }
            discard_task (t);
        }

        private void discard_task (Task t) {
            TaskRow? row = null;
            for (var child = list.get_first_child (); child != null; child = child.get_next_sibling ()) {
                var tr = child as TaskRow;
                if (tr != null && tr.task == t) row = tr;
            }
            if (row != null) {
                animator.remove (row, () => discard_now (t));
                return;
            }
            discard_now (t);
        }

        private void discard_now (Task t) {
            store.trash (t, new DateTime.now_utc ());
            changed_now ();
            if (detail != null && (detail.task == t || store.is_ancestor (t, detail.task))) close_detail ();
        }

        public void restore_task (Task t) {
            store.restore (t);
            changed_now ();
            if (detail != null && detail.task == t) reload_detail ();
        }

        private void confirm_purge (Task t) {
            var dlg = new ConfirmDialog (app, _("Delete %s Forever?").printf (t.title != "" ? t.title : _("This Task")), "user-trash-symbolic",
                _("The task and its subtasks cannot be restored afterwards."), _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                store.purge (t);
                changed_now ();
            });
            dlg.present ();
        }

        private void confirm_empty_trash () {
            int n = store.count_trashed ();
            if (n == 0) return;
            var dlg = new ConfirmDialog (app, _("Empty the Trash?"), "user-trash-symbolic",
                ngettext ("%d task will be deleted forever.", "%d tasks will be deleted forever.", n).printf (n), _("Empty Trash"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                store.empty_trash ();
                changed_now ();
            });
            dlg.present ();
        }

        private void set_due_in (Task t, int days) {
            var n = new DateTime.now_local ();
            if (days < 0) {
                t.due = null;
                t.due_has_time = false;
            } else {
                t.due = new DateTime.local (n.get_year (), n.get_month (), n.get_day_of_month (), 0, 0, 0).add_days (days);
                t.due_has_time = false;
            }
            t.reminded = 0;
            task_edited (t, true);
            reload_detail ();
        }

        private void place_menu (ContextMenu menu, Widget anchor, double x, double y) {
            menu.pointing_to = { (int) x, (int) y, 1, 1 };
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        public void task_menu (TaskRow row, double x, double y) {
            var t = row.task;
            list.select_row (row);
            var menu = new ContextMenu (row);
            if (t.trashed) {
                menu.add_item (_("Restore"), "edit-undo-symbolic", () => restore_task (t));
                menu.add_separator ();
                menu.add_item (_("Delete Forever"), "user-trash-symbolic", () => confirm_purge (t), "destructive-action");
                place_menu (menu, row, x, y);
                return;
            }
            menu.add_item (_("Open"), "document-edit-symbolic", () => show_task (t));
            if (store.is_read_only (t)) {
                place_menu (menu, row, x, y);
                return;
            }
            menu.add_item (t.completed ? _("Mark as Not Done") : _("Mark as Done"), "object-select-symbolic", () => set_done (t, !t.completed));
            menu.add_item (_("Start Focus Timer"), "media-playback-start-symbolic", () => focus_on (t));
            menu.add_item (_("Add Subtask"), "list-add-symbolic", () => {
                show_task (t);
                Idle.add (() => {
                    var sub = store.add_task (t.list_id, "", t.uid);
                    t.expanded = true;
                    changed_now ();
                    show_task (sub);
                    detail.focus_title ();
                    return Source.REMOVE;
                });
            });
            var due = menu.add_submenu (_("Due"), "x-office-calendar-symbolic");
            due.add_item (_("Today"), null, () => set_due_in (t, 0));
            due.add_item (_("Tomorrow"), null, () => set_due_in (t, 1));
            due.add_item (_("Next Week"), null, () => set_due_in (t, 7));
            if (t.due != null) due.add_item (_("No Date"), null, () => set_due_in (t, -1));
            var pri = menu.add_submenu (_("Priority"), "tasks-priority-symbolic");
            foreach (var p in new Priority[] { Priority.HIGH, Priority.MEDIUM, Priority.LOW, Priority.NONE }) {
                var chosen = p;
                pri.add_item (p.label (), p == t.priority ? "object-select-symbolic" : null, () => {
                    t.priority = chosen;
                    task_edited (t, true);
                    reload_detail ();
                });
            }
            if (store.lists.size > 1) {
                var move = menu.add_submenu (_("Move To"), "view-list-symbolic");
                foreach (var l in store.lists) {
                    if ((l.id == t.list_id && t.parent_uid == "") || l.read_only) continue;
                    var target = l;
                    move.add_item (l.label (), null, () => move_to_list (t, target));
                }
            }
            if (t.parent_uid != "") {
                menu.add_item (_("Make Top-Level Task"), "go-up-symbolic", () => {
                    if (store.move (t, t.list_id, "", int.MAX)) changed_now ();
                });
            }
            menu.add_separator ();
            if (store.is_online (t)) menu.add_item (_("Delete…"), "user-trash-symbolic", () => trash_task (t), "destructive-action");
            else menu.add_item (_("Move to Trash"), "user-trash-symbolic", () => trash_task (t), "destructive-action");
            place_menu (menu, row, x, y);
        }

        private void list_menu (Widget anchor, TaskList l, double x, double y) {
            var menu = new ContextMenu (anchor);
            fill_list_menu (menu, l);
            place_menu (menu, anchor, x, y);
        }

        private void fill_list_menu (ContextMenu menu, TaskList l) {
            if (l.online) {
                menu.add_item (_("Sync Now"), "view-refresh-symbolic", () => app.online.sync_now (l));
                menu.add_item (_("Export…"), "document-save-symbolic", () => export_tasks.begin (l));
                menu.add_item (app.show_completed ? _("Hide Done Tasks") : _("Show Done Tasks"), "object-select-symbolic", () => app.activate_action ("show-completed", null));
                if (!l.read_only && store.completed_in (l.id).size > 0) menu.add_item (_("Clear Done Tasks…"), "edit-clear-all-symbolic", () => clear_completed (l));
                menu.add_separator ();
                menu.add_item (_("Online Accounts"), "emblem-system-symbolic", () => open_accounts ());
                return;
            }
            menu.add_item (_("Rename…"), "document-edit-symbolic", () => rename_list (l));
            menu.add_item (_("Export…"), "document-save-symbolic", () => export_tasks.begin (l));
            if (app.online.writable_accounts (true).size > 0) menu.add_item (_("Move to Account..."), "folder-remote-symbolic", () => choose_destination (l));
            menu.add_item (app.show_completed ? _("Hide Done Tasks") : _("Show Done Tasks"), "object-select-symbolic", () => app.activate_action ("show-completed", null));
            if (store.completed_in (l.id).size > 0) menu.add_item (_("Clear Done Tasks"), "edit-clear-all-symbolic", () => clear_completed (l));
            menu.add_separator ();
            menu.add_item (_("Delete List…"), "user-trash-symbolic", () => confirm_delete_list (l), "destructive-action");
        }

        private void show_more () {
            var l = current_list ();
            if (l == null) return;
            var menu = new ContextMenu (stack);
            Graphene.Rect bounds;
            if (more_bubble.compute_bounds (stack, out bounds)) {
                var rect = Gdk.Rectangle ();
                rect.x = (int) bounds.origin.x;
                rect.y = (int) bounds.origin.y;
                rect.width = (int) bounds.size.width;
                rect.height = (int) bounds.size.height;
                menu.pointing_to = rect;
            }
            menu.position = PositionType.BOTTOM;
            fill_list_menu (menu, l);
            menu.closed.connect (() => Idle.add (() => {
                menu.unparent ();
                return Source.REMOVE;
            }));
            menu.popup ();
        }

        private void clear_completed (TaskList l) {
            if (l.read_only) return;
            int n = store.completed_in (l.id).size;
            if (l.online && n > 0) {
                var dlg = new ConfirmDialog (app, _("Delete the Done Tasks?"), "user-trash-symbolic",
                    ngettext ("%d task is deleted from %s.", "%d tasks are deleted from %s.", n).printf (n, l.account_name), _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
                dlg.transient_for = this;
                dlg.modal = true;
                dlg.response.connect ((r) => {
                    if (r != ConfirmDialog.Response.PRIMARY) return;
                    discard_completed (l);
                });
                dlg.present ();
                return;
            }
            discard_completed (l);
        }

        private void discard_completed (TaskList l) {
            var now = new DateTime.now_utc ();
            foreach (var t in store.completed_in (l.id)) store.trash (t, now);
            changed_now ();
        }

        private delegate void NameCallback (string name);

        private void ask_name (string heading, string action, string initial, owned NameCallback done) {
            var dlg = new ConfirmDialog (app, heading, null, null, action, ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_default_size (400, 0);
            var group = new PreferencesGroup ();
            var entry = new EntryRow (_("List Name"));
            entry.text = initial;
            group.add_row (entry);
            dlg.custom_area.append (group);
            dlg.primary_sensitive = initial.strip () != "";
            entry.entry_changed.connect (() => dlg.primary_sensitive = entry.text.strip () != "");
            entry.entry_activated.connect (() => {
                if (entry.text.strip () == "") return;
                done (entry.text.strip ());
                dlg.close_dialog ();
            });
            dlg.response.connect ((r) => {
                if (r == ConfirmDialog.Response.PRIMARY && entry.text.strip () != "") done (entry.text.strip ());
            });
            dlg.present ();
            entry.grab_focus ();
        }

        public void new_list () {
            choose_destination (null);
        }

        private void choose_destination (TaskList? source) {
            var owners = app.online.writable_accounts (source != null);
            var options = new Gee.ArrayList<Singularity.Core.AppSettingOption> ();
            if (source == null) options.add (new Singularity.Core.AppSettingOption () { id = "", label = _("On This Device") });
            foreach (var owner in owners) options.add (new Singularity.Core.AppSettingOption () { id = owner.account.id, label = owner.account.display_name });
            if (options.size == 0) return;
            var dlg = new ConfirmDialog (app, source != null ? _("Move %s to an Account?").printf (source.name) : _("New List"), null,
                source != null ? _("Google stores due dates without a time. Recurrence, reminders, tags and priorities stay on this device. The local list is kept until every task is accepted.") : null,
                source != null ? _("Move List") : _("Create"), ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.set_default_size (440, 0);
            var group = new PreferencesGroup ();
            var entry = new EntryRow (_("List Name"));
            if (source == null) group.add_row (entry);
            string selected = options[0].id;
            var account = new SelectionRow.with_options (_("Account"), options, selected);
            account.selected.connect ((id) => selected = id);
            group.add_row (account);
            dlg.custom_area.append (group);
            dlg.primary_sensitive = source != null;
            entry.entry_changed.connect (() => dlg.primary_sensitive = entry.text.strip () != "");
            dlg.response.connect ((response) => {
                if (response != ConfirmDialog.Response.PRIMARY) return;
                if (source == null && entry.text.strip () == "") return;
                if (selected == "") {
                    var created = store.add_list (entry.text.strip ());
                    changed_now ();
                    select_view ("list:" + created.id);
                    return;
                }
                Singularity.Accounts.CollectionSet? owner = null;
                foreach (var candidate in owners) if (candidate.account.id == selected) owner = candidate;
                if (owner == null) return;
                run_destination (source, owner, entry.text.strip ());
            });
            dlg.present ();
            if (source == null) entry.grab_focus ();
        }

        private void run_destination (TaskList? source, Singularity.Accounts.CollectionSet owner, string name) {
            var cancellable = new Cancellable ();
            var progress = new ConfirmDialog (app, source != null ? _("Moving List") : _("Creating List"), "folder-remote-symbolic",
                _("Waiting for the account to confirm the destination."), _("Stop"), ConfirmDialog.ActionStyle.DEFAULT);
            progress.transient_for = this;
            progress.modal = true;
            progress.response.connect (() => cancellable.cancel ());
            progress.present ();
            if (source != null) {
                app.online.transfer_list.begin (app.storage, source, owner, cancellable, (o, result) => {
                    try {
                        string id = app.online.transfer_list.end (result);
                        progress.close_dialog ();
                        changed_now ();
                        select_view ("list:" + id);
                    } catch (Error e) {
                        progress.close_dialog ();
                        show_error (_("The Local List Has Been Kept"), e.message);
                    }
                });
            } else {
                app.online.create_list.begin (owner, name, cancellable, (o, result) => {
                    try {
                        string id = app.online.create_list.end (result);
                        progress.close_dialog ();
                        changed_now ();
                        select_view ("list:" + id);
                    } catch (Error e) {
                        progress.close_dialog ();
                        show_error (_("The List Could Not Be Created"), e.message);
                    }
                });
            }
        }

        public void rename_list (TaskList? l) {
            if (l == null || l.online) return;
            ask_name (_("Rename List"), _("Rename"), l.name, (name) => {
                l.name = name;
                changed_now ();
            });
        }

        private void confirm_delete_list (TaskList? l) {
            if (l == null || l.online) return;
            int n = store.count_open (l.id);
            var dlg = new ConfirmDialog (app, _("Delete %s?").printf (l.name), "user-trash-symbolic",
                n > 0 ? ngettext ("Its %d open task moves to the trash.", "Its %d open tasks move to the trash.", n).printf (n) : _("Its tasks move to the trash."),
                _("Delete"), ConfirmDialog.ActionStyle.DESTRUCTIVE);
            dlg.transient_for = this;
            dlg.modal = true;
            dlg.response.connect ((r) => {
                if (r != ConfirmDialog.Response.PRIMARY) return;
                store.remove_list (l, new DateTime.now_utc ());
                changed_now ();
            });
            dlg.present ();
        }

        public void import_file () {
            var dialog = new FileDialog ();
            dialog.title = _("Import Tasks");
            var filters = new GLib.ListStore (typeof (FileFilter));
            var f = new FileFilter ();
            f.name = _("iCalendar Files");
            f.add_suffix ("ics");
            f.add_suffix ("ical");
            f.add_suffix ("ifb");
            f.add_mime_type ("text/calendar");
            filters.append (f);
            dialog.filters = filters;
            dialog.open_multiple.begin (this, null, (o, res) => {
                try {
                    var files = dialog.open_multiple.end (res);
                    for (uint i = 0; i < files.get_n_items (); i++) import_ics.begin ((File) files.get_item (i));
                } catch (Error e) {
                }
            });
        }

        public async void import_ics (File file) {
            try {
                uint8[] data;
                yield file.load_contents_async (null, out data, null);
                string text = (string) data;
                if (!text.validate ()) text = convert (text, -1, "UTF-8", "WINDOWS-1252");
                string calname;
                var items = ICal.parse (text, out calname);
                if (items.size == 0) {
                    show_error (_("No Tasks Found"), _("%s has no tasks in it. Only to-do items (VTODO) are imported, not events.").printf (file.get_basename ()));
                    return;
                }
                string fallback = file.get_basename () ?? _("Imported");
                int dot = fallback.last_index_of (".");
                if (dot > 0) fallback = fallback.substring (0, dot);
                int n = ICal.import_into (store, items, calname, fallback);
                changed_now ();
                if (items.size > 0) {
                    var first = store.find (items[0].task.uid);
                    if (first != null) select_view ("list:" + first.list_id);
                }
                subtitle.label = ngettext ("%d task imported", "%d tasks imported", n).printf (n);
                subtitle.visible = true;
            } catch (Error e) {
                show_error (_("Could Not Import"), e.message);
            }
        }

        public async void export_tasks (TaskList? l) {
            var items = new Gee.ArrayList<Task> ();
            string name;
            if (l != null) {
                items.add_all (store.in_order (l.id));
                name = l.name;
            } else {
                foreach (var each in store.lists) items.add_all (store.in_order (each.id));
                name = _("Tasks");
            }
            var dialog = new FileDialog ();
            dialog.title = _("Export Tasks");
            dialog.initial_name = name.replace ("/", "-") + ".ics";
            try {
                var file = yield dialog.save (this, null);
                if (file == null) return;
                string text = ICal.export (items, store, l != null ? l.name : null, new DateTime.now_utc ());
                yield file.replace_contents_async (text.data, null, false, FileCreateFlags.REPLACE_DESTINATION, null, null);
            } catch (Error e) {
                if (!(e is Gtk.DialogError)) show_error (_("Could Not Export"), e.message);
            }
        }

        public void show_error (string heading, string message) {
            var dlg = new ConfirmDialog.message (app, heading, "dialog-error-symbolic", message);
            dlg.transient_for = this;
            dlg.present ();
        }

        public void reveal_task (string uid) {
            var t = store.find (uid);
            if (t == null) return;
            if (t.trashed) select_view (TRASH);
            else select_view ("list:" + t.list_id);
            if (!t.trashed) {
                var p = store.parent_of (t);
                bool changed = false;
                while (p != null) {
                    if (!p.expanded) {
                        p.expanded = true;
                        changed = true;
                    }
                    p = store.parent_of (p);
                }
                if (changed) refresh ();
            }
            show_task (t);
        }

        private void install_actions () {
            string[] names = { "new-task", "new-list", "import", "export-list", "export-all", "find", "rename-list", "delete-list", "clear-completed", "delete-task", "view-today", "view-upcoming", "view-trash", "focus-task", "empty-trash", "close", "sync-now" };
            foreach (string n in names) {
                var a = new SimpleAction (n, null);
                string name = n;
                a.activate.connect (() => {
                    switch (name) {
                        case "new-task": focus_add (); break;
                        case "new-list": new_list (); break;
                        case "import": import_file (); break;
                        case "export-list": if (current_list () != null) export_tasks.begin (current_list ()); break;
                        case "export-all": if (store.lists.size > 0) export_tasks.begin (null); break;
                        case "find": focus_search (); break;
                        case "rename-list": rename_list (current_list ()); break;
                        case "delete-list": confirm_delete_list (current_list ()); break;
                        case "clear-completed": if (current_list () != null) clear_completed (current_list ()); break;
                        case "delete-task":
                            var tr = list.get_selected_row () as TaskRow;
                            if (tr != null && !tr.task.trashed) trash_task (tr.task);
                            break;
                        case "view-today": if (stack.visible_child_name == "main") select_view (TODAY); break;
                        case "view-upcoming": if (stack.visible_child_name == "main") select_view (UPCOMING); break;
                        case "view-trash": if (stack.visible_child_name == "main") select_view (TRASH); break;
                        case "focus-task":
                            var sel = list.get_selected_row () as TaskRow;
                            Task? target = detail != null && panel_revealer.reveal_child ? detail.task : (sel != null ? sel.task : null);
                            if (target != null) focus_on (target);
                            break;
                        case "empty-trash": confirm_empty_trash (); break;
                        case "close": close (); break;
                        case "sync-now": app.online.sync_now (null); break;
                    }
                });
                add_action (a);
            }
            list.row_selected.connect (() => sync_actions ());
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((keyval, code, state) => {
                if (keyval != Gdk.Key.Escape) return false;
                if (panel_revealer.reveal_child) {
                    close_detail ();
                    return true;
                }
                if (query != "") {
                    search.clear ();
                    return true;
                }
                return false;
            });
            ((Widget) this).add_controller (keys);
        }
    }
}
