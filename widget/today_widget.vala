using Gtk;
using Singularity;
using Singularity.Apps.Tasks;

namespace SingularityTasksWidget {

    public class TodayProvider : Object, OverviewWidgetProvider {
        public string id           { get { return "tasks.today"; } }
        public string provider_id  { get { return "dev.sinty.tasks"; } }
        public string display_name { get { return _("Today's Tasks"); } }
        public string icon_name    { get { return "dev.sinty.tasks"; } }
        public WidgetSize[] supported_sizes {
            get {
                if (_sizes == null) {
                    _sizes = new WidgetSize[2];
                    _sizes[0] = WidgetSize (2, 2);
                    _sizes[1] = WidgetSize (2, 3);
                }
                return _sizes;
            }
        }
        private WidgetSize[] _sizes;

        public Gtk.Widget create_instance (string instance_id, WidgetSize size, Variant? config) {
            return new TodayInstance (size);
        }
    }

    public class TodayInstance : Gtk.Box {
        private FileMonitor? monitor = null;
        private OnlineMirror? online = null;
        private Gtk.Box list;
        private Label count_label;
        private Entry entry;
        private uint tick_id = 0;
        private int max_rows;
        private int last_day = 0;

        public TodayInstance (WidgetSize size) {
            Object (orientation: Orientation.VERTICAL, spacing: 6);
            TodayRows.ensure_css ();
            add_css_class ("overview-tasks");
            hexpand = true;
            vexpand = true;
            max_rows = size.h >= 3 ? 7 : 4;

            var header = new Gtk.Box (Orientation.HORIZONTAL, 6);
            var title = new Label (_("Today"));
            title.add_css_class ("heading");
            title.xalign = 0;
            title.hexpand = true;
            header.append (title);
            count_label = new Label ("");
            count_label.add_css_class ("overview-tasks-count");
            header.append (count_label);
            append (header);

            list = new Gtk.Box (Orientation.VERTICAL, 0);
            list.vexpand = true;
            append (list);

            entry = new Entry ();
            entry.placeholder_text = _("Add a task for today");
            entry.primary_icon_name = "list-add-symbolic";
            entry.add_css_class ("overview-tasks-entry");
            entry.activate.connect (() => {
                string text = entry.text.strip ();
                if (text == "") return;
                entry.text = "";
                TodayRows.call_app ("add-task-today", new Variant.string (text), null);
            });
            append (entry);

            var file = File.new_for_path (Storage.default_path ());
            try {
                DirUtils.create_with_parents (Path.get_dirname (file.get_path ()), 0700);
                monitor = file.monitor_file (FileMonitorFlags.WATCH_MOVES, null);
                monitor.set_rate_limit (200);
                monitor.changed.connect ((f, other, type) => {
                    if (type == FileMonitorEvent.CHANGES_DONE_HINT || type == FileMonitorEvent.CREATED || type == FileMonitorEvent.DELETED || type == FileMonitorEvent.RENAMED || type == FileMonitorEvent.MOVED_IN) reload ();
                });
            } catch (Error e) {
                warning ("tasks widget: %s", e.message);
            }
            online = new OnlineMirror ();
            online.changed.connect (() => reload ());
            tick_id = Timeout.add_seconds (60, () => {
                if (TaskStore.date_key (new DateTime.now_local ()) != last_day) reload ();
                return Source.CONTINUE;
            });
            reload ();

            destroy.connect (() => {
                if (tick_id != 0) Source.remove (tick_id);
                tick_id = 0;
                if (monitor != null) monitor.cancel ();
                monitor = null;
                if (online != null) online.stop ();
                online = null;
            });
        }

        private void reload () {
            var now = new DateTime.now_local ();
            last_day = TaskStore.date_key (now);
            var store = new TaskStore ();
            bool ok = true;
            try {
                string data;
                FileUtils.get_contents (Storage.default_path (), out data);
                Storage.deserialize (data, store);
            } catch (Error e) {
                ok = false;
            }
            if (online != null) {
                online.fill (store);
                ok = true;
            }
            Widget? child;
            while ((child = list.get_first_child ()) != null) list.remove (child);
            var due = ok ? store.today (now) : new Gee.ArrayList<Singularity.Apps.Tasks.Task> ();
            count_label.label = due.size > 0 ? due.size.to_string () : "";
            if (due.size == 0) {
                var empty = new Label (_("Nothing due today"));
                empty.add_css_class ("dim-label");
                empty.vexpand = true;
                empty.valign = Align.CENTER;
                list.append (empty);
                return;
            }
            int shown = 0;
            foreach (var t in due) {
                if (shown >= max_rows) break;
                list.append (TodayRows.row (t, now));
                shown++;
            }
            if (due.size > shown) {
                int rest = due.size - shown;
                var more = new Button.with_label (ngettext ("%d more task", "%d more tasks", rest).printf (rest));
                more.has_frame = false;
                more.halign = Align.START;
                more.add_css_class ("caption");
                more.clicked.connect (() => TodayRows.call_app ("show-today", null, null));
                list.append (more);
            }
        }

    }

    [CCode (cname = "singularity_tasks_widget_new")]
    public static Object singularity_tasks_widget_new () {
        return new TodayProvider ();
    }
}
