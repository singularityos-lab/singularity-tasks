using GLib;

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Plugin), typeof (TasksBadgePlugin));
}

public class TasksBadgePlugin : Object, Singularity.Plugin {
    private const string APP_URI = "application://dev.sinty.tasks.desktop";
    private const string OBJECT_PATH = "/dev/sinty/tasks/LauncherEntry";
    private DBusConnection? bus = null;
    private FileMonitor? monitor = null;
    private uint tick_id = 0;
    private uint reload_id = 0;
    private int last_day = 0;
    private int64 last_count = -1;
    private Singularity.Accounts.CollectionTracker? tracker = null;
    private Gee.ArrayList<ulong> tracker_handlers = new Gee.ArrayList<ulong> ();

    public void activate (Singularity.PluginContext context) {
        Bus.get.begin (BusType.SESSION, null, (obj, res) => {
            try {
                bus = Bus.get.end (res);
                update ();
            } catch (Error e) {
                warning ("tasks-badge: %s", e.message);
            }
        });
        var file = File.new_for_path (tasks_path ());
        try {
            DirUtils.create_with_parents (Path.get_dirname (file.get_path ()), 0700);
            monitor = file.monitor_file (FileMonitorFlags.WATCH_MOVES, null);
            monitor.set_rate_limit (300);
            monitor.changed.connect ((f, other, type) => {
                if (type == FileMonitorEvent.CHANGES_DONE_HINT || type == FileMonitorEvent.CREATED || type == FileMonitorEvent.DELETED || type == FileMonitorEvent.RENAMED || type == FileMonitorEvent.MOVED_IN) queue_update ();
            });
        } catch (Error e) {
            warning ("tasks-badge: %s", e.message);
        }
        tracker = Singularity.Accounts.CollectionTracker.get_shared (Singularity.Accounts.ContentKind.TASKS);
        tracker_handlers.add (tracker.set_added.connect (() => queue_update ()));
        tracker_handlers.add (tracker.set_removed.connect (() => queue_update ()));
        tracker_handlers.add (tracker.collections_changed.connect (() => queue_update ()));
        tracker_handlers.add (tracker.changed.connect (() => queue_update ()));
        tracker_handlers.add (tracker.notify["ready"].connect (() => queue_update ()));
        tick_id = Timeout.add_seconds (60, () => {
            if (day_key (new DateTime.now_local ()) != last_day) update ();
            return Source.CONTINUE;
        });
    }

    public void deactivate () {
        if (tick_id != 0) Source.remove (tick_id);
        if (reload_id != 0) Source.remove (reload_id);
        tick_id = 0;
        reload_id = 0;
        if (monitor != null) monitor.cancel ();
        monitor = null;
        if (tracker != null) foreach (ulong h in tracker_handlers) tracker.disconnect (h);
        tracker_handlers.clear ();
        tracker = null;
        last_count = -1;
        emit (0);
    }

    public Gtk.Widget? get_settings_widget () {
        return null;
    }

    private static string tasks_path () {
        return Path.build_filename (Environment.get_user_data_dir (), "singularity", "tasks", "tasks.json");
    }

    private static int day_key (DateTime d) {
        var l = d.to_local ();
        return l.get_year () * 10000 + l.get_month () * 100 + l.get_day_of_month ();
    }

    private static int due_key (string text) {
        if (text.length == 10) {
            int y = 0, m = 0, d = 0;
            if (text.scanf ("%d-%d-%d", out y, out m, out d) != 3) return 0;
            return y * 10000 + m * 100 + d;
        }
        var dt = new DateTime.from_iso8601 (text, new TimeZone.local ());
        return dt != null ? day_key (dt) : 0;
    }

    private void queue_update () {
        if (reload_id != 0) return;
        reload_id = Timeout.add (150, () => {
            reload_id = 0;
            update ();
            return Source.REMOVE;
        });
    }

    private int64 count_due () {
        string data;
        try {
            FileUtils.get_contents (tasks_path (), out data);
        } catch (Error e) {
            return 0;
        }
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (data);
        } catch (Error e) {
            return 0;
        }
        var root = parser.get_root ();
        if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return 0;
        var o = root.get_object ();
        if (!o.has_member ("tasks")) return 0;
        var lists = new GenericSet<string> (str_hash, str_equal);
        if (o.has_member ("lists")) {
            foreach (var node in o.get_array_member ("lists").get_elements ()) {
                var lo = node.get_object ();
                if (lo != null && lo.has_member ("id")) lists.add (lo.get_string_member ("id"));
            }
        }
        int today = day_key (new DateTime.now_local ());
        int64 count = 0;
        foreach (var node in o.get_array_member ("tasks").get_elements ()) {
            var to = node.get_object ();
            if (to == null) continue;
            if (to.get_boolean_member_with_default ("completed", false)) continue;
            if (to.has_member ("trashed_at")) continue;
            if (!lists.contains (to.get_string_member_with_default ("list", ""))) continue;
            int key = due_key (to.get_string_member_with_default ("due", ""));
            if (key > 0 && key <= today) count++;
        }
        return count;
    }

    private static int ical_day (Singularity.Accounts.ContentLine line) {
        string v = line.value.strip ();
        if (v.length < 8) return 0;
        if (v.length >= 16 && v.has_suffix ("Z")) {
            var dt = new DateTime.from_iso8601 ("%s-%s-%sT%s:%s:%sZ".printf (v.substring (0, 4), v.substring (4, 2), v.substring (6, 2),
                v.substring (9, 2), v.substring (11, 2), v.substring (13, 2)), null);
            return dt != null ? day_key (dt) : 0;
        }
        return int.parse (v.substring (0, 8));
    }

    private int64 count_online () {
        if (tracker == null || !tracker.ready) return 0;
        int today = day_key (new DateTime.now_local ());
        int64 count = 0;
        foreach (var set in tracker.get_sets ()) {
            foreach (var c in set.collections) {
                foreach (var item in c.items ()) {
                    if (item.state == Singularity.Accounts.SyncState.DELETED) continue;
                    var cal = Singularity.Accounts.Component.parse (item.data);
                    var todo = cal != null ? (cal.name == "VTODO" ? cal : cal.get_child ("VTODO")) : null;
                    if (todo == null) continue;
                    string status = todo.get_value ("STATUS").up ();
                    if (status == "COMPLETED" || status == "CANCELLED" || todo.get_line ("COMPLETED") != null) continue;
                    var due = todo.get_line ("DUE");
                    if (due == null) continue;
                    int key = ical_day (due);
                    if (key > 0 && key <= today) count++;
                }
            }
        }
        return count;
    }

    private void update () {
        last_day = day_key (new DateTime.now_local ());
        int64 count = count_due () + count_online ();
        if (count == last_count) return;
        last_count = count;
        emit (count);
    }

    private void emit (int64 count) {
        if (bus == null) return;
        var props = new VariantBuilder (new VariantType ("a{sv}"));
        props.add ("{sv}", "count", new Variant.int64 (count));
        props.add ("{sv}", "count-visible", new Variant.boolean (count > 0));
        try {
            bus.emit_signal (null, OBJECT_PATH, "com.canonical.Unity.LauncherEntry", "Update",
                new Variant ("(s@a{sv})", APP_URI, props.end ()));
        } catch (Error e) {
            warning ("tasks-badge: %s", e.message);
        }
    }
}
