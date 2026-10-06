namespace Singularity.Apps.Tasks {

    public class TasksSearch : Singularity.SearchProviderService {
        private const int MAX_RESULTS = 12;
        private const string ADD_PREFIX = "add:";
        private TasksApp app;

        public TasksSearch (TasksApp app) {
            this.app = app;
        }

        private static string? add_text (string[] terms) {
            string query = string.joinv (" ", terms).strip ();
            if (!query.has_prefix ("+")) return null;
            string text = query.substring (1).strip ();
            return text != "" ? text : null;
        }

        public override async string[] get_initial_results (string[] terms, Cancellable? cancellable) throws Error {
            string? text = add_text (terms);
            if (text != null) return { ADD_PREFIX + text };
            string query = string.joinv (" ", terms).strip ();
            if (query.char_count () < 2 || app.load_error != null) return {};
            string[] ids = {};
            foreach (var t in app.store.search (query)) {
                if (ids.length >= MAX_RESULTS) break;
                if (t.title.strip () == "") continue;
                ids += t.uid;
            }
            return ids;
        }

        public override async Singularity.SearchResultMeta[] get_result_metas (string[] ids, Cancellable? cancellable) throws Error {
            Singularity.SearchResultMeta[] metas = {};
            var now = new DateTime.now_local ();
            int rank = 0;
            foreach (string id in ids) {
                if (id.has_prefix (ADD_PREFIX)) {
                    string text = id.substring (ADD_PREFIX.length);
                    var entry = QuickParser.parse (text, now);
                    var meta = new Singularity.SearchResultMeta (id, _("Add “%s”").printf (entry.title != "" ? entry.title : text));
                    var parts = new GenericArray<string> ();
                    if (entry.due != null) {
                        var probe = new Task ();
                        probe.due = entry.due;
                        probe.due_has_time = entry.due_has_time;
                        parts.add (_("Due %s").printf (TaskFormat.due (probe, now)));
                    }
                    if (entry.priority != Priority.NONE) parts.add (_("%s Priority").printf (entry.priority.label ()));
                    foreach (string tag in entry.tags) parts.add ("#" + tag);
                    meta.description = parts.length > 0 ? string.joinv (", ", parts.data) : _("New task in Tasks");
                    meta.icon = new ThemedIcon ("dev.sinty.tasks");
                    meta.score = 1000;
                    metas += meta;
                    continue;
                }
                var t = app.store.find (id);
                if (t == null) continue;
                var meta = new Singularity.SearchResultMeta (id, t.title);
                var parts = new GenericArray<string> ();
                if (t.completed) parts.add (_("Done"));
                else if (t.due != null) parts.add (_("Due %s").printf (TaskFormat.due (t, now)));
                var l = app.store.list (t.list_id);
                if (l != null) parts.add (l.name);
                meta.description = string.joinv (", ", parts.data);
                meta.icon = new ThemedIcon ("dev.sinty.tasks");
                if (!t.completed) meta.add_action ("complete", _("Mark as Done"), "object-select-symbolic");
                meta.score = 100 - rank;
                rank++;
                metas += meta;
            }
            return metas;
        }

        public override async Singularity.SearchActivationReply? activate_result (string id, string[] terms, uint32 timestamp) throws Error {
            if (id.has_prefix (ADD_PREFIX)) {
                app.quick_add (id.substring (ADD_PREFIX.length), false);
                return null;
            }
            app.activate_action ("show-task", new Variant.string (id));
            return null;
        }

        public override async Singularity.SearchActivationReply? activate_action (string id, string action_id, string[] terms, uint32 timestamp) throws Error {
            if (action_id == "complete") app.activate_action ("complete-task", new Variant.string (id));
            return null;
        }
    }
}
