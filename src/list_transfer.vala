using Singularity.Accounts;

namespace Singularity.Apps.Tasks {

    [CCode (cname = "open", cheader_filename = "fcntl.h")]
    private extern int transfer_open (string path, int flags, int mode);
    [CCode (cname = "close", cheader_filename = "unistd.h")]
    private extern int transfer_close (int fd);
    [CCode (cname = "flock", cheader_filename = "sys/file.h")]
    private extern int transfer_flock (int fd, int operation);
    [CCode (cname = "O_RDWR", cheader_filename = "fcntl.h")]
    private extern const int TRANSFER_O_RDWR;
    [CCode (cname = "O_CREAT", cheader_filename = "fcntl.h")]
    private extern const int TRANSFER_O_CREAT;
    [CCode (cname = "O_CLOEXEC", cheader_filename = "fcntl.h")]
    private extern const int TRANSFER_O_CLOEXEC;
    [CCode (cname = "LOCK_EX", cheader_filename = "sys/file.h")]
    private extern const int TRANSFER_LOCK_EX;
    [CCode (cname = "LOCK_NB", cheader_filename = "sys/file.h")]
    private extern const int TRANSFER_LOCK_NB;

    public class ListTransfer : Object {
        private TaskStore store;
        private Storage storage;
        private CollectionSet owner;
        private TaskList source;
        private Json.Object journal;
        private Json.Object acknowledgements;
        private TaskStore snapshot = new TaskStore ();
        private string path;
        private HttpClient http;
        private string base_url;

        public ListTransfer (TaskStore store, Storage storage, CollectionSet owner, TaskList source) {
            this.store = store;
            this.storage = storage;
            this.owner = owner;
            this.source = source;
            string key = Checksum.compute_for_string (ChecksumType.SHA256, source.id);
            path = Path.build_filename (Environment.get_user_data_dir (), "singularity", "tasks", "transfers", key + ".json");
            http = new HttpClient (owner.account, Capability.TASKS);
            base_url = owner.account.get_endpoint ("google-tasks") ?? "https://tasks.googleapis.com/tasks/v1/";
            if (!base_url.has_suffix ("/")) base_url += "/";
        }

        private static string text (Json.Object o, string name, bool required = false) throws Error {
            if (!o.has_member (name)) {
                if (!required) return "";
                throw new IOError.INVALID_DATA (_("The server response has no %s").printf (name));
            }
            var node = o.get_member (name);
            if (!required && node.get_node_type () == Json.NodeType.NULL) return "";
            if (node.get_node_type () != Json.NodeType.VALUE || node.get_value ().type () != typeof (string)) {
                throw new IOError.INVALID_DATA (_("The server response has an invalid %s").printf (name));
            }
            string value = node.get_string ();
            if (required && (value.strip () == "" || value.strip () != value)) throw new IOError.INVALID_DATA (_("The server response has an invalid %s").printf (name));
            return value;
        }

        private static string json (Json.Object o) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (o);
            var gen = new Json.Generator ();
            gen.set_root (node);
            return gen.to_data (null);
        }

        private void save () throws Error {
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            FileUtils.set_contents_full (path, json (journal), -1, FileSetContentsFlags.CONSISTENT | FileSetContentsFlags.DURABLE, 0600);
        }

        private string source_snapshot () {
            var local = new TaskStore ();
            local.lists.add (new TaskList (source.id, source.name));
            foreach (var t in store.tasks) if (t.list_id == source.id && !t.trashed) local.tasks.add (t);
            return Storage.serialize (local);
        }

        private void load () throws Error {
            if (FileUtils.test (path, FileTest.EXISTS)) {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                if (parser.get_root ().get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("The list transfer record is damaged"));
                journal = parser.get_root ().get_object ();
                if (text (journal, "account", true) != owner.account.id || text (journal, "source", true) != source.id) {
                    throw new IOError.INVALID_DATA (_("Resume this transfer with its original account"));
                }
                if (text (journal, "snapshot", true) != source_snapshot ()) {
                    throw new IOError.BUSY (_("The local list changed since the transfer. Its original remains available; review the destination before continuing."));
                }
                if (!journal.has_member ("acknowledgements") || journal.get_member ("acknowledgements").get_node_type () != Json.NodeType.OBJECT) {
                    throw new IOError.INVALID_DATA (_("The list transfer acknowledgements are damaged"));
                }
            } else {
                journal = new Json.Object ();
                journal.set_string_member ("account", owner.account.id);
                journal.set_string_member ("source", source.id);
                journal.set_string_member ("snapshot", source_snapshot ());
                journal.set_object_member ("acknowledgements", new Json.Object ());
                journal.set_string_member ("inflight", "");
                journal.set_boolean_member ("creation-pending", false);
                save ();
            }
            acknowledgements = journal.get_object_member ("acknowledgements");
            Storage.deserialize (text (journal, "snapshot", true), snapshot);
        }

        private Gee.List<Task> ordered () throws Error {
            var result = new Gee.ArrayList<Task> ();
            var uids = new Gee.HashSet<string> ();
            foreach (var t in snapshot.tasks) {
                if (t.uid == "" || !uids.add (t.uid)) throw new IOError.INVALID_DATA (_("The list contains an empty or repeated task identifier"));
                if (t.parent_uid != "" && snapshot.find (t.parent_uid) == null) throw new IOError.INVALID_DATA (_("A task's parent is missing from the list"));
                if (snapshot.depth (t) >= 64) throw new IOError.INVALID_DATA (_("The list contains a circular task hierarchy"));
                if (t.title.char_count () > 1024 || t.notes.char_count () > 8192) throw new IOError.INVALID_DATA (_("A task exceeds Google's title or notes limit. The local list has been kept."));
                result.add (t);
            }
            result.sort ((a, b) => {
                int depth = snapshot.depth (a) - snapshot.depth (b);
                if (depth != 0) return depth;
                int parent = strcmp (a.parent_uid, b.parent_uid);
                return parent != 0 ? parent : a.position - b.position;
            });
            return result;
        }

        private Json.Object body_for (Task t) throws Error {
            var one = new Gee.ArrayList<Task> ();
            one.add (t);
            return Converters.ical_todo_to_google (ICal.export (one, snapshot, null, t.modified));
        }

        private bool matches (Json.Object response, Json.Object body, string parent) throws Error {
            string due = text (body, "due");
            string got_due = text (response, "due");
            return text (response, "title", true) == text (body, "title", true)
                && text (response, "notes") == text (body, "notes")
                && text (response, "status", true) == text (body, "status", true)
                && (due == got_due || (due.length >= 10 && got_due.length >= 10 && due.substring (0, 10) == got_due.substring (0, 10)))
                && text (response, "parent") == parent;
        }

        private async RemoteCollection destination (Cancellable? cancellable) throws Error {
            if (journal.has_member ("destination")) {
                if (journal.get_member ("destination").get_node_type () != Json.NodeType.OBJECT) throw new IOError.INVALID_DATA (_("The destination record is damaged"));
                var remote = Collections.from_descriptor (owner.account, ContentKind.TASKS, journal.get_object_member ("destination"));
                if (remote == null || remote.read_only) throw new IOError.INVALID_DATA (_("The destination is unavailable"));
                return remote;
            }
            var found = yield Collections.discover (owner.account, ContentKind.TASKS, cancellable);
            if (journal.get_boolean_member ("creation-pending")) {
                var before = journal.get_array_member ("before");
                var ids = new Gee.HashSet<string> ();
                foreach (var node in before.get_elements ()) ids.add (node.get_string ());
                RemoteCollection? matched = null;
                foreach (var remote in found) {
                    if (ids.contains (remote.id) || remote.name != source.name) continue;
                    if (matched != null) throw new IOError.BUSY (_("More than one destination matches the interrupted creation. The local list has been kept."));
                    matched = remote;
                }
                if (matched == null) throw new IOError.BUSY (_("The previous creation has no confirmed destination yet. Retry when the account shows it; the local list has been kept."));
                journal.set_object_member ("destination", matched.to_descriptor ());
                journal.set_boolean_member ("creation-pending", false);
                save ();
                return matched;
            }
            var before = new Json.Array ();
            foreach (var remote in found) before.add_string_element (remote.id);
            journal.set_array_member ("before", before);
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            journal.set_boolean_member ("creation-pending", true);
            save ();
            RemoteCollection created;
            try {
                created = yield Collections.create (owner.account, ContentKind.TASKS, source.name, cancellable);
            } catch (Error e) {
                if (e is AccountsError.AUTH_FAILED || e is AccountsError.NEEDS_REAUTH || e is AccountsError.INVALID
                    || e is AccountsError.NOT_FOUND || e is AccountsError.CONFLICT) {
                    journal.set_boolean_member ("creation-pending", false);
                    save ();
                }
                throw e;
            }
            journal.set_object_member ("destination", created.to_descriptor ());
            journal.set_boolean_member ("creation-pending", false);
            save ();
            return created;
        }

        private async void reconcile (RemoteCollection remote, Task t, Json.Object body, string parent, Cancellable? cancellable) throws Error {
            var index = yield remote.list_index (cancellable);
            var known = new Gee.HashSet<string> ();
            foreach (string uid in acknowledgements.get_members ()) known.add (text (acknowledgements.get_object_member (uid), "id", true));
            Json.Object? match = null;
            foreach (string id in index.keys) {
                if (known.contains (id)) continue;
                var response = yield http.send_ok ("GET", base_url + "lists/" + Uri.escape_string (text (remote.to_descriptor (), "remote-id", true), null, false) + "/tasks/" + Uri.escape_string (id, null, false), null, null, null, cancellable);
                var item = response.json_object ();
                if (!matches (item, body, parent)) continue;
                if (match != null) throw new IOError.BUSY (_("More than one task matches the interrupted upload. The local list has been kept."));
                match = item;
            }
            if (match == null) throw new IOError.BUSY (_("The previous task upload has no confirmed acknowledgement yet. The local list has been kept; no duplicate was sent."));
            text (match, "id", true);
            acknowledgements.set_object_member (t.uid, match);
            journal.set_string_member ("inflight", "");
            save ();
        }

        public async string run (Cancellable? cancellable = null) throws Error {
            DirUtils.create_with_parents (Path.get_dirname (path), 0700);
            int fd = transfer_open (Path.build_filename (Path.get_dirname (path), "transfer.lock"), TRANSFER_O_RDWR | TRANSFER_O_CREAT | TRANSFER_O_CLOEXEC, 0600);
            if (fd < 0) throw new IOError.FAILED (_("The transfer lock could not be opened"));
            if (transfer_flock (fd, TRANSFER_LOCK_EX | TRANSFER_LOCK_NB) != 0) {
                transfer_close (fd);
                throw new IOError.BUSY (_("Another list transfer is still running"));
            }
            try {
                return yield execute (cancellable);
            } finally {
                transfer_close (fd);
            }
        }

        private async string execute (Cancellable? cancellable) throws Error {
            if (!store.lists.contains (source) || source.online || !owner.account.healthy || !owner.account.has_capability (Capability.TASKS)
                || Collections.api_for (owner.account, ContentKind.TASKS) != "google") throw new IOError.INVALID_ARGUMENT (_("Choose a signed-in Google task account for this local list"));
            storage.save (store);
            load ();
            var tasks = ordered ();
            var remote = yield destination (cancellable);
            var collection = owner.add_created (remote);
            collection.cancel_scheduled ();
            string list_id = text (remote.to_descriptor (), "remote-id", true);
            string url = base_url + "lists/" + Uri.escape_string (list_id, null, false) + "/tasks";
            var previous = new Gee.HashMap<string, string> ();
            var positions = new Gee.HashMap<string, string> ();
            foreach (var t in tasks) {
                if (cancellable != null) cancellable.set_error_if_cancelled ();
                string parent = t.parent_uid != "" ? text (acknowledgements.get_object_member (t.parent_uid), "id", true) : "";
                string prior = previous[parent] ?? "";
                var body = body_for (t);
                if (!acknowledgements.has_member (t.uid)) {
                    if (text (journal, "inflight") != "") {
                        if (text (journal, "inflight") != t.uid) throw new IOError.INVALID_DATA (_("The interrupted task does not match the saved order"));
                        yield reconcile (remote, t, body, parent, cancellable);
                    } else {
                        yield http.send_ok ("GET", url + "?showCompleted=true&showHidden=true&maxResults=1", null, null, null, cancellable);
                        journal.set_string_member ("inflight", t.uid);
                        save ();
                        string query = "?";
                        if (parent != "") query += "parent=" + Uri.escape_string (parent, null, false) + "&";
                        if (prior != "") query += "previous=" + Uri.escape_string (prior, null, false);
                        HttpResponse response;
                        try {
                            response = yield http.send ("POST", url + query, "application/json", new Bytes (json (body).data), null, cancellable);
                        } catch (AccountsError.NEEDS_REAUTH e) {
                            journal.set_string_member ("inflight", "");
                            save ();
                            throw e;
                        }
                        if (response.status >= 400 && response.status < 500) {
                            journal.set_string_member ("inflight", "");
                            save ();
                        }
                        HttpClient.check (response, "Upload task");
                        var item = response.json_object ();
                        text (item, "id", true);
                        acknowledgements.set_object_member (t.uid, item);
                        journal.set_string_member ("inflight", "");
                        save ();
                    }
                }
                string id = text (acknowledgements.get_object_member (t.uid), "id", true);
                var accepted = yield http.send_ok ("GET", url + "/" + Uri.escape_string (id, null, false), null, null, null, cancellable);
                if (!matches (accepted.json_object (), body, parent)) throw new IOError.INVALID_DATA (_("The destination task differs from the local task. The local list has been kept."));
                string position = text (accepted.json_object (), "position", true);
                if (positions.has_key (parent) && strcmp (positions[parent], position) >= 0) throw new IOError.INVALID_DATA (_("The destination order differs from the local list. The local list has been kept."));
                positions[parent] = position;
                previous[parent] = id;
            }
            if (cancellable != null) cancellable.set_error_if_cancelled ();
            bool synced = yield collection.sync (cancellable);
            if (!synced || collection.pending_changes () != 0) throw new IOError.FAILED (_("The acknowledged destination could not be saved locally: %s").printf (collection.last_error));
            var persisted = new SyncedCollection (owner.account.id, remote, ContentKind.TASKS, owner.directory);
            foreach (var t in tasks) {
                string id = text (acknowledgements.get_object_member (t.uid), "id", true);
                var item = persisted.get_item (id);
                if (item == null || item.href != id || item.state != SyncState.CLEAN) throw new IOError.FAILED (_("A task acknowledgement is missing from the saved destination. The local list has been kept."));
            }
            if (source_snapshot () != text (journal, "snapshot", true)) throw new IOError.BUSY (_("The local list changed during transfer and has been kept"));
            string destination_id = OnlineTasks.list_id_for (owner.account, collection);
            var metadata = new TransferMetadata ();
            metadata.load ();
            foreach (var t in snapshot.tasks) {
                t.uid = text (acknowledgements.get_object_member (t.uid), "id", true);
                t.list_id = destination_id;
                metadata.remember (t);
            }
            metadata.save ();
            journal.set_boolean_member ("retired", true);
            save ();
            var removed = new Gee.ArrayList<Task> ();
            foreach (var t in store.tasks.to_array ()) {
                if (t.list_id == source.id && !t.trashed) {
                    removed.add (t);
                    store.tasks.remove (t);
                }
            }
            bool keep_trash = false;
            foreach (var t in store.tasks) if (t.list_id == source.id) keep_trash = true;
            if (!keep_trash) store.lists.remove (source);
            try {
                storage.save (store);
            } catch (Error e) {
                if (!store.lists.contains (source)) store.lists.add (source);
                store.tasks.add_all (removed);
                throw e;
            }
            return destination_id;
        }
    }
}
