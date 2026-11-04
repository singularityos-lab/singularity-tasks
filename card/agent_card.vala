using Gtk;
using Singularity.Apps.Tasks;

namespace SingularityTasksWidget {

    public class AgentCard : Object {
        private const int MAX_ROWS = 7;

        private static string uid_of (Json.Node node) {
            if (node.get_node_type () != Json.NodeType.OBJECT) return "";
            var o = node.get_object ();
            return o.has_member ("uid") ? o.get_string_member ("uid") : "";
        }

        public static Widget? build (string intent, string args, string result) {
            Json.Node root;
            try {
                root = Json.from_string (result);
            } catch (Error e) {
                return null;
            }
            if (root == null) return null;
            var uids = new Gee.ArrayList<string> ();
            if (root.get_node_type () == Json.NodeType.ARRAY) {
                foreach (var n in root.get_array ().get_elements ()) uids.add (uid_of (n));
            } else {
                uids.add (uid_of (root));
            }
            var store = new TaskStore ();
            try {
                string data;
                FileUtils.get_contents (Storage.default_path (), out data);
                Storage.deserialize (data, store);
            } catch (Error e) {
                return null;
            }
            TodayRows.ensure_css ();
            var now = new DateTime.now_local ();
            var list = new Box (Orientation.VERTICAL, 2);
            int shown = 0;
            foreach (var uid in uids) {
                var t = store.find (uid);
                if (t == null) continue;
                if (shown == MAX_ROWS) {
                    var more = new Button.with_label (_("%d more").printf (uids.size - shown));
                    more.has_frame = false;
                    more.halign = Align.START;
                    more.add_css_class ("caption");
                    more.clicked.connect (() => TodayRows.call_app ("show-today", null, null));
                    list.append (more);
                    break;
                }
                list.append (TodayRows.row (t, now));
                shown++;
            }
            if (shown == 0) {
                var none = new Label (_("Nothing to do"));
                none.add_css_class ("dim-label");
                none.xalign = 0;
                list.append (none);
            }
            return list;
        }
    }

    [CCode (cname = "singularity_tasks_card_new")]
    public Widget? agent_card_new (string intent, string args, string result) {
        return AgentCard.build (intent, args, result);
    }
}
