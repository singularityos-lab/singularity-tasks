using Singularity.Accounts;
using Singularity.Apps.Tasks;

int main (string[] args) {
    Gtk.init ();
    assert (Environment.get_variable ("DISPLAY") == null);
    assert (Environment.get_variable ("SINGULARITY_SYSTEM_BUS") == Environment.get_variable ("DBUS_SYSTEM_BUS_ADDRESS"));
    assert (args.length == 3);
    var loop = new MainLoop ();
    var manager = Manager.get_default ();
    int status = 1;
    manager.load.begin ((o, loaded) => {
        manager.load.end (loaded);
        var account = manager.get_account ("synthetic-google");
        assert (account != null);
        var store = new TaskStore ();
        var storage = new Storage (Environment.get_variable ("TASKS_STORAGE_PATH") ?? Storage.default_path ());
        try {
            assert (storage.load (store));
            var source = store.list ("local-list");
            if (source == null && args[1] == "retired") source = new TaskList ("local-list", "Local Research");
            assert (source != null);
            string before = Storage.serialize (store);
            var owner = new CollectionSet (account, ContentKind.TASKS);
            var cancellable = new Cancellable ();
            if (args[1] == "cancel") Timeout.add (800, () => {
                cancellable.cancel ();
                return Source.REMOVE;
            });
            var transfer = new ListTransfer (store, storage, owner, source);
            transfer.run.begin (cancellable, (obj, completed) => {
                try {
                    string id = transfer.run.end (completed);
                    assert (args[2] == "success");
                    assert (store.list ("local-list") == null && store.tasks.size == 0);
                    var reopened = new TaskStore ();
                    assert (storage.load (reopened));
                    assert (reopened.list ("local-list") == null && reopened.tasks.size == 0);
                    var metadata = new TransferMetadata ();
                    metadata.load ();
                    var remote = owner.collections[0];
                    var restored = new SyncedCollection (account.id, remote.remote, ContentKind.TASKS, owner.directory);
                    assert (restored.items ().size == 4 && restored.pending_changes () == 0);
                    bool root = false, child = false, completed_task = false;
                    foreach (var item in restored.items ()) {
                        assert (item.state == SyncState.CLEAN && item.href != "");
                        string name;
                        var task = ICal.parse (item.data, out name)[0].task;
                        task.uid = item.uid;
                        task.list_id = id;
                        assert (metadata.restore (task));
                        if (task.title == "Parent") {
                            root = true;
                            assert (task.position == 2 && task.rrule == "FREQ=WEEKLY;BYDAY=MO");
                            assert (task.reminder_minutes == 30 && task.priority == Singularity.Apps.Tasks.Priority.HIGH);
                            assert (task.tags_text () == "Work" && task.due_has_time);
                        }
                        if (task.title == "Child") {
                            child = true;
                            assert (task.parent_uid != "" && task.parent_uid != "local-parent");
                        }
                        if (task.title == "Done") completed_task = task.completed;
                    }
                    assert (root && child && completed_task);
                    stdout.printf ("TRANSFER SUCCESS destination=%s acknowledged=4 metadata=preserved source=retired\n", id);
                    status = 0;
                } catch (Error e) {
                    stderr.printf ("TRANSFER ERROR: %s\n", e.message);
                    assert (args[2] == "failure");
                    assert (before == Storage.serialize (store));
                    var reopened = new TaskStore ();
                    assert (storage.load (reopened));
                    assert (before == Storage.serialize (reopened));
                    stdout.printf ("TRANSFER FAILURE source=serialized-equivalent restart=preserved error=%s\n", e.message);
                    status = 0;
                }
                loop.quit ();
            });
        } catch (Error e) {
            stderr.printf ("TEST ERROR: %s\n", e.message);
            loop.quit ();
        }
    });
    loop.run ();
    return status;
}
