namespace Singularity.Apps.Tasks {

    internal class TasksIntents : Object {
        private const string UID = "{\"type\":\"object\",\"properties\":{\"uid\":{\"type\":\"string\"}},\"required\":[\"uid\"]}";

        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        private static Json.Node brief (Task t) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("uid").add_string_value (t.uid);
            b.set_member_name ("title").add_string_value (t.title);
            b.set_member_name ("notes").add_string_value (t.notes);
            b.set_member_name ("completed").add_boolean_value (t.completed);
            b.set_member_name ("due").add_string_value (t.due != null ? t.due.format_iso8601 () : "");
            b.set_member_name ("tags").add_string_value (t.tags_text ());
            b.end_object ();
            return b.get_root ();
        }

        private static Json.Node matching (TasksApp app, string query, bool completed, int64 limit) {
            var list = new Json.Array ();
            foreach (var t in app.store.tasks) {
                if (t.trashed || t.completed != completed) continue;
                if (query != "" && !t.matches (query)) continue;
                if (list.get_length () == limit) break;
                list.add_element (brief (t));
            }
            var node = new Json.Node (Json.NodeType.ARRAY);
            node.set_array (list);
            return node;
        }

        private static Task find (TasksApp app, Json.Object args) throws Error {
            var t = app.store.find (text (args, "uid"));
            if (t == null) throw new IOError.NOT_FOUND ("no task with this uid");
            return t;
        }

        internal static void install (TasksApp app) {
            var agent = app.agent;
            agent.add_intent ("task_list", "List tasks, open by default.",
                "{\"type\":\"object\",\"properties\":{\"completed\":{\"type\":\"boolean\"},\"limit\":{\"type\":\"integer\"}}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    bool done = args.has_member ("completed") && args.get_boolean_member ("completed");
                    return matching (app, "", done, args.has_member ("limit") ? args.get_int_member ("limit") : 100);
                });
            agent.add_intent ("task_search", "Find open tasks by words.",
                "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}",
                Singularity.AppIntentRisk.READ, (args) => matching (app, text (args, "query"), false, 100));
            agent.add_intent ("task_add", "Add a task. The text may say a date, as in the quick add field.",
                "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var t = app.quick_add (text (args, "text"), false);
                    if (t == null) throw new IOError.INVALID_ARGUMENT ("the task could not be added");
                    app.flush ();
                    return brief (t);
                });
            agent.add_intent ("task_complete", "Mark a task as done, or open it again.",
                "{\"type\":\"object\",\"properties\":{\"uid\":{\"type\":\"string\"},\"done\":{\"type\":\"boolean\"}},\"required\":[\"uid\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var t = find (app, args);
                    bool done = !args.has_member ("done") || args.get_boolean_member ("done");
                    app.activate_action ("set-task-completed", new Variant ("(sb)", t.uid, done));
                    app.flush ();
                    return brief (t);
                });
            agent.add_intent ("task_show", "Open a task in the window.", UID,
                Singularity.AppIntentRisk.READ, (args) => {
                    var t = find (app, args);
                    app.activate_action ("show-task", new Variant.string (t.uid));
                    return brief (t);
                });
        }
    }
}
