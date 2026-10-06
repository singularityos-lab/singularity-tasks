namespace Singularity.Apps.Tasks {

    public class TransferMetadata : Object {
        private TaskStore saved = new TaskStore ();
        private Storage storage = new Storage (Path.build_filename (Environment.get_user_data_dir (), "singularity", "tasks", "transfer-metadata.json"));

        public void load () throws Error {
            storage.load (saved);
        }

        public void remember (Task t) {
            foreach (var old in saved.tasks.to_array ()) {
                if (old.list_id == t.list_id && old.uid == t.uid) saved.tasks.remove (old);
            }
            if (saved.list (t.list_id) == null) saved.lists.add (new TaskList (t.list_id, ""));
            saved.tasks.add (t);
        }

        public void save () throws Error {
            storage.save (saved);
        }

        public bool restore (Task t) {
            foreach (var old in saved.tasks) {
                if (old.list_id != t.list_id || old.uid != t.uid) continue;
                if (old == t) return true;
                t.rrule = old.rrule;
                t.reminder_minutes = old.reminder_minutes;
                t.reminder_at = old.reminder_at;
                t.reminded = old.reminded;
                t.priority = old.priority;
                t.tags.clear ();
                t.tags.add_all (old.tags);
                t.extra.clear ();
                t.extra.add_all (old.extra);
                t.focus_seconds = old.focus_seconds;
                t.position = old.position;
                t.expanded = old.expanded;
                t.created = old.created;
                if (t.due != null && old.due != null && TaskStore.date_key (t.due) == TaskStore.date_key (old.due)) {
                    t.due = old.due;
                    t.due_has_time = old.due_has_time;
                }
                return true;
            }
            return false;
        }

        public void update (TaskStore store) throws Error {
            var keys = new Gee.HashSet<string> ();
            foreach (var t in saved.tasks) keys.add (t.list_id + ":" + t.uid);
            foreach (var t in store.tasks) {
                if (store.is_online (t) && keys.contains (t.list_id + ":" + t.uid)) remember (t);
            }
            save ();
        }
    }
}
