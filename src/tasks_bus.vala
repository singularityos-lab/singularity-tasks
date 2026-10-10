namespace Singularity.Apps.Tasks {

    [DBus (name = "dev.sinty.Tasks1")]
    public class TasksBus : Object {
        private unowned TasksApp app;

        public signal void changed ();

        public TasksBus (TasksApp app) {
            this.app = app;
            app.store.changed.connect (() => changed ());
        }

        public string add_task (string text) throws Error {
            var t = app.quick_add (text, false);
            if (t == null) throw new IOError.INVALID_ARGUMENT (_("The task could not be added"));
            return t.uid;
        }

        public void add_linked_task (string uid, string text) throws Error {
            app.activate_action ("add-linked-task", new Variant ("(ss)", uid, text));
        }

        public void set_completed (string uid, bool done) throws Error {
            app.activate_action ("set-task-completed", new Variant ("(sb)", uid, done));
        }

        public void show_task (string uid) throws Error {
            app.activate_action ("show-task", new Variant.string (uid));
        }

        public HashTable<string, bool> get_states (string[] uids) throws Error {
            var states = new HashTable<string, bool> (str_hash, str_equal);
            foreach (string uid in uids) {
                var t = app.store.find (uid);
                if (t != null) states[uid] = t.completed;
            }
            return states;
        }
    }
}
