namespace Singularity.Apps.Tasks.Tests {

DateTime local (int y, int m, int d, int h = 0, int min = 0) {
    return new DateTime.local (y, m, d, h, min, 0);
}

string fixture (string name) {
    return Path.build_filename (Environment.get_variable ("TASKS_FIXTURES"), name);
}

string temp_path (string name) {
    return Path.build_filename (Environment.get_tmp_dir (), "tasks-%d-%s".printf (Random.int_range (0, 1000000), name));
}

string titles (Gee.List<Task> list) {
    string[] out_v = {};
    foreach (var t in list) out_v += t.title;
    return string.joinv (",", out_v);
}

void test_progress () {
    var s = new TaskStore ();
    var l = s.add_list ("Home");
    var parent = s.add_task (l.id, "Move house");
    var a = s.add_task (l.id, "Pack", parent.uid);
    var b = s.add_task (l.id, "Book van", parent.uid);
    var a1 = s.add_task (l.id, "Books", a.uid);
    var a2 = s.add_task (l.id, "Kitchen", a.uid);
    int done, total;
    s.progress (parent, out done, out total);
    assert (done == 0 && total == 4);
    var now = new DateTime.now_utc ();
    s.set_completed (a1, true, now);
    s.progress (parent, out done, out total);
    assert (done == 1 && total == 4);
    s.progress (a, out done, out total);
    assert (done == 1 && total == 2);
    s.set_completed (a, true, now);
    assert (a2.completed && a2.completed_at != null);
    s.progress (parent, out done, out total);
    assert (done == 3 && total == 4);
    s.set_completed (a2, false, now);
    assert (!a.completed && !a2.completed && a1.completed);
    s.set_completed (parent, true, now);
    assert (b.completed && a.completed && a2.completed);
    s.set_completed (a1, false, now);
    assert (!a.completed && !parent.completed && b.completed);
    assert (s.depth (a1) == 2 && s.depth (parent) == 0);
    assert (s.has_children (a) && !s.has_children (b));
    s.trash (b, now);
    s.progress (parent, out done, out total);
    assert (total == 3);
}

void test_ordering () {
    var s = new TaskStore ();
    var l = s.add_list ("Work");
    var other = s.add_list ("Other");
    var a = s.add_task (l.id, "A");
    var b = s.add_task (l.id, "B");
    var c = s.add_task (l.id, "C");
    var d = s.add_task (l.id, "D");
    assert (titles (s.children (l.id, "")) == "A,B,C,D");
    assert (s.move_next_to (d, a, false));
    assert (titles (s.children (l.id, "")) == "D,A,B,C");
    assert (s.move_next_to (d, b, true));
    assert (titles (s.children (l.id, "")) == "A,B,D,C");
    assert (s.move (c, l.id, "", 0));
    assert (titles (s.children (l.id, "")) == "C,A,B,D");
    assert (s.move (b, l.id, a.uid, int.MAX));
    assert (titles (s.children (l.id, "")) == "C,A,D");
    assert (titles (s.children (l.id, a.uid)) == "B");
    var b1 = s.add_task (l.id, "B1", b.uid);
    assert (!s.move (a, l.id, b1.uid, 0));
    assert (!s.move (a, l.id, a.uid, 0));
    assert (!s.move_next_to (a, b1, true));
    assert (titles (s.in_order (l.id)) == "C,A,B,B1,D");
    assert (s.move_next_to (b1, c, false));
    assert (b1.parent_uid == "" && titles (s.children (l.id, "")) == "B1,C,A,D");
    assert (s.move (b1, l.id, b.uid, 0));
    assert (s.move_to_list (a, other.id));
    assert (a.list_id == other.id && b.list_id == other.id && b1.list_id == other.id);
    assert (b.parent_uid == a.uid);
    assert (titles (s.children (l.id, "")) == "C,D");
    assert (titles (s.in_order (other.id)) == "A,B,B1");
    assert (!s.move_to_list (a, other.id));
    assert (!s.move_to_list (a, "missing"));
    int prev = -1;
    foreach (var t in s.children (l.id, "")) {
        assert (t.position > prev);
        prev = t.position;
    }
}

void test_smart_lists () {
    var s = new TaskStore ();
    var l = s.add_list ("Inbox");
    var now = local (2026, 9, 26, 15, 0);
    var overdue = s.add_task (l.id, "Overdue");
    overdue.due = local (2026, 9, 20);
    var today_late = s.add_task (l.id, "Today late");
    today_late.due = local (2026, 9, 26, 23, 30);
    today_late.due_has_time = true;
    var today_plain = s.add_task (l.id, "Today");
    today_plain.due = local (2026, 9, 26);
    today_plain.priority = Priority.HIGH;
    var tomorrow = s.add_task (l.id, "Tomorrow");
    tomorrow.due = local (2026, 9, 27);
    var later = s.add_task (l.id, "Later");
    later.due = local (2026, 10, 3, 8, 0);
    later.due_has_time = true;
    var done = s.add_task (l.id, "Done");
    done.due = local (2026, 9, 25);
    s.set_completed (done, true, now);
    var undated = s.add_task (l.id, "Undated");
    var gone = s.add_task (l.id, "Gone");
    gone.due = local (2026, 9, 26);
    s.trash (gone, now);
    var sub = s.add_task (l.id, "Sub", undated.uid);
    sub.due = local (2026, 9, 26, 9, 0);
    sub.due_has_time = true;
    assert (titles (s.today (now)) == "Overdue,Today,Sub,Today late");
    assert (titles (s.upcoming (now)) == "Tomorrow,Later");
    var just_after_midnight = local (2026, 9, 27, 0, 5);
    assert (titles (s.upcoming (just_after_midnight)) == "Later");
    assert (s.today (just_after_midnight).size == 5);
    assert (TaskStore.date_key (local (2026, 9, 26, 23, 59)) == 20260926);
    assert (TaskFormat.day (local (2026, 9, 27), now) == "Tomorrow");
    assert (TaskFormat.day (local (2026, 9, 25, 10), now) == "Yesterday");
    assert (TaskFormat.day (local (2026, 9, 26, 22), now) == "Today");
    assert (TaskFormat.day (local (2027, 1, 5), now) == "5 Jan 2027");
    assert (TaskFormat.due (later, now) == "3 Oct, 08:00");
}

void test_search_and_trash () {
    var s = new TaskStore ();
    var l = s.add_list ("Shopping");
    var milk = s.add_task (l.id, "Buy milk");
    milk.tags.add ("groceries");
    var bread = s.add_task (l.id, "Bread");
    bread.notes = "From the bakery on Main Street";
    var crumbs = s.add_task (l.id, "Crumbs", bread.uid);
    assert (titles (s.search ("milk")) == "Buy milk");
    assert (titles (s.search ("BAKERY")) == "Bread");
    assert (titles (s.search ("#groceries")) == "Buy milk");
    assert (s.search ("#grocer").size == 0);
    assert (s.search ("grocer").size == 1);
    assert (s.search ("buy bakery").size == 0);
    var now = new DateTime.now_utc ();
    s.trash (bread, now);
    assert (bread.trashed && crumbs.trashed);
    assert (s.search ("bakery").size == 0);
    assert (titles (s.trashed_roots ()) == "Bread");
    assert (s.count_trashed () == 2);
    s.restore (bread);
    assert (!bread.trashed && !crumbs.trashed && crumbs.parent_uid == bread.uid);
    s.trash (crumbs, now);
    s.trash (bread, now.add_seconds (5));
    s.restore (crumbs);
    assert (!crumbs.trashed && crumbs.parent_uid == "" && bread.trashed);
    s.remove_list (l, now);
    assert (s.lists.size == 0 && milk.trashed);
    s.restore (milk);
    assert (s.lists.size == 1 && milk.list_id == s.lists[0].id && !milk.trashed);
    s.purge (bread);
    assert (s.find (bread.uid) == null);
    s.trash (milk, now);
    s.empty_trash ();
    assert (s.find (milk.uid) == null && s.count_trashed () == 0);
}

void test_reminders () {
    var s = new TaskStore ();
    var l = s.add_list ("R");
    var t = s.add_task (l.id, "Call");
    t.due = local (2026, 9, 26, 10, 0);
    t.due_has_time = true;
    t.reminder_minutes = 15;
    assert (t.reminder_time ().equal (local (2026, 9, 26, 9, 45)));
    var all_day = s.add_task (l.id, "Pay rent");
    all_day.due = local (2026, 9, 28);
    all_day.reminder_minutes = 0;
    assert (all_day.reminder_time ().equal (local (2026, 9, 28, 9, 0)));
    var abs = s.add_task (l.id, "Absolute");
    abs.reminder_at = local (2026, 9, 26, 9, 50);
    assert (s.due_reminders (local (2026, 9, 26, 9, 40)).size == 0);
    assert (s.next_reminder (local (2026, 9, 26, 9, 40)).equal (local (2026, 9, 26, 9, 45)));
    var due_now = s.due_reminders (local (2026, 9, 26, 9, 55));
    assert (titles (due_now) == "Call,Absolute");
    foreach (var d in due_now) d.reminded = d.reminder_time ().to_unix ();
    assert (s.due_reminders (local (2026, 9, 26, 9, 56)).size == 0);
    t.reminder_minutes = 5;
    assert (titles (s.due_reminders (local (2026, 9, 26, 9, 56))) == "Call");
    assert (s.due_reminders (local (2026, 9, 29, 12, 0)).size == 0);
    s.set_completed (all_day, true, new DateTime.now_utc ());
    assert (s.due_reminders (local (2026, 9, 28, 9, 1)).size == 0);
}

void test_json_round_trip () {
    var s = new TaskStore ();
    var l = s.add_list ("Casa \"quoted\"");
    var l2 = s.add_list ("Empty");
    var p = s.add_task (l.id, "Parent ✓");
    p.notes = "line 1\nline 2";
    p.due = local (2026, 12, 24);
    p.priority = Priority.MEDIUM;
    p.tags.add ("x");
    p.tags.add ("y z");
    p.rrule = "FREQ=YEARLY";
    p.extra.add ("X-FOO;BAR=1:baz");
    p.expanded = false;
    p.reminder_minutes = 60;
    var c = s.add_task (l.id, "Child", p.uid);
    c.due = local (2026, 12, 23, 18, 45);
    c.due_has_time = true;
    s.set_completed (c, true, local (2026, 9, 26, 12, 0));
    c.reminder_at = local (2026, 12, 23, 18, 0);
    c.reminded = 1234;
    s.trash (c, local (2026, 9, 27, 8, 0));
    string json = Storage.serialize (s);
    var back = new TaskStore ();
    try {
        Storage.deserialize (json, back);
    } catch (Error e) {
        error ("%s", e.message);
    }
    assert (back.lists.size == 2 && back.lists[0].name == "Casa \"quoted\"" && back.lists[1].id == l2.id);
    var bp = back.find (p.uid);
    var bc = back.find (c.uid);
    assert (bp != null && bc != null);
    assert (bp.title == "Parent ✓" && bp.notes == "line 1\nline 2" && bp.list_id == l.id);
    assert (bp.due.equal (p.due) && !bp.due_has_time);
    assert (bp.priority == Priority.MEDIUM && bp.tags.size == 2 && bp.tags[1] == "y z");
    assert (bp.rrule == "FREQ=YEARLY" && bp.extra.size == 1 && bp.extra[0] == "X-FOO;BAR=1:baz");
    assert (!bp.expanded && bp.reminder_minutes == 60 && !bp.completed);
    assert (bc.parent_uid == p.uid && bc.due.equal (c.due) && bc.due_has_time);
    assert (bc.completed && bc.completed_at.equal (c.completed_at));
    assert (bc.trashed_at.equal (c.trashed_at) && bc.reminder_at.equal (c.reminder_at) && bc.reminded == 1234);
    assert (bc.created.equal (c.created) && bc.position == c.position);
    assert (Storage.serialize (back) == json);

    string path = temp_path ("store/tasks.json");
    var storage = new Storage (path);
    try {
        storage.save (s);
        var loaded = new TaskStore ();
        assert (storage.load (loaded));
        assert (loaded.tasks.size == 2 && loaded.lists.size == 2);
        storage.save (loaded);
        string text;
        FileUtils.get_contents (path, out text);
        assert (text == json);
        Posix.Stat st;
        Posix.stat (path, out st);
        assert ((st.st_mode & 0777) == 0600);
        FileUtils.set_contents (path, "{ broken");
        var broken = new TaskStore ();
        try {
            storage.load (broken);
            assert_not_reached ();
        } catch (Error e) {
            assert (e is IOError.INVALID_DATA);
        }
        assert (!FileUtils.test (path, FileTest.EXISTS));
        var missing = new TaskStore ();
        assert (!storage.load (missing));
        var dir = Dir.open (Path.get_dirname (path));
        string? name;
        while ((name = dir.read_name ()) != null) FileUtils.remove (Path.build_filename (Path.get_dirname (path), name));
        DirUtils.remove (Path.get_dirname (path));
    } catch (Error e) {
        error ("%s", e.message);
    }
}

void test_escaping_and_folding () {
    assert (ICal.escape ("a,b;c\\d\ne") == "a\\,b\\;c\\\\d\\ne");
    assert (ICal.unescape ("a\\,b\\;c\\\\d\\ne\\Nf") == "a,b;c\\d\ne\nf");
    var parts = ICal.split_list ("one,two\\,three, four");
    assert (parts.size == 3 && parts[1] == "two,three" && parts[2] == " four");
    string long_line = "SUMMARY:" + string.nfill (70, 'x') + "éèà€☎ and more text that keeps going past the limit";
    string folded = ICal.fold (long_line);
    assert (folded.has_suffix ("\r\n"));
    foreach (string physical in folded.split ("\r\n")) {
        assert (physical.length <= 75);
        assert (physical.validate ());
    }
    var lines = ICal.unfold (folded);
    assert (lines.size == 1 && lines[0] == long_line);
    assert (ICal.fold ("SHORT:x") == "SHORT:x\r\n");
    var mixed = ICal.unfold ("A:1\n B\r\n\tC\r\nD:2\r\n\r\n");
    assert (mixed.size == 2 && mixed[0] == "A:1BC" && mixed[1] == "D:2");
    var p = ICal.parse_line ("ATTENDEE;CN=\"Doe; John\";ROLE=REQ:mailto:j@x.test");
    assert (p.name == "ATTENDEE" && p.param ("CN") == "Doe; John" && p.param ("ROLE") == "REQ" && p.value == "mailto:j@x.test");
    int64 secs;
    assert (ICal.parse_duration ("-PT15M", out secs) && secs == -900);
    assert (ICal.parse_duration ("-P1DT2H", out secs) && secs == -93600);
    assert (ICal.parse_duration ("P1W", out secs) && secs == 604800);
    assert (ICal.parse_duration ("PT0S", out secs) && secs == 0);
    assert (!ICal.parse_duration ("15M", out secs));
    assert (!ICal.parse_duration ("P1H", out secs));
    assert (ICal.format_duration_before (15) == "-PT15M" && ICal.format_duration_before (120) == "-PT2H" && ICal.format_duration_before (2880) == "-P2D");
}

Gee.List<ImportedTask> load_sample (out string calname) {
    string text;
    try {
        FileUtils.get_contents (fixture ("sample.ics"), out text);
    } catch (Error e) {
        error ("%s", e.message);
    }
    return ICal.parse (text, out calname);
}

void test_import () {
    string calname;
    var items = load_sample (out calname);
    assert (calname == "Home, Garden");
    assert (items.size == 3);
    var p = items[0].task;
    assert (p.uid == "todo-parent@example.com");
    assert (p.title == "Plant the tomatoes, peppers; and basil");
    assert (p.notes == "Buy seeds first.\nThen water them every day, twice if it is hot outside. Remember the fertilizer: 20\\30 mix.");
    assert (p.due.equal (local (2026, 9, 28)) && !p.due_has_time);
    assert (p.priority == Priority.HIGH);
    assert (p.tags.size == 3 && p.tags[0] == "garden" && p.tags[2] == "spring,summer");
    assert (p.rrule == "FREQ=WEEKLY;BYDAY=SA;COUNT=4");
    assert (p.extra.size == 2 && p.extra[0] == "X-EXAMPLE-COLOR:#00ff00" && p.extra[1] == "LOCATION:Backyard");
    assert (p.reminder_minutes == 30 && p.reminder_at == null);
    assert (p.created.equal (new DateTime.utc (2026, 9, 1, 8, 0, 0)));
    assert (!p.completed);
    var c = items[1].task;
    assert (c.parent_uid == p.uid && c.completed && c.priority == Priority.MEDIUM);
    assert (c.due_has_time && c.due.equal (new DateTime.utc (2026, 9, 27, 13, 0, 0)));
    assert (c.completed_at.equal (new DateTime.utc (2026, 9, 26, 12, 0, 0)));
    var t3 = items[2].task;
    assert (t3.title == "Chiamare l'idraulico ☎" && t3.priority == Priority.LOW);
    assert (t3.due.equal (new DateTime.utc (2026, 10, 1, 15, 30, 0)));
    assert (t3.reminder_at.equal (new DateTime.utc (2026, 10, 1, 15, 0, 0)));

    var s = new TaskStore ();
    s.add_list ("Existing");
    int n = ICal.import_into (s, items, calname, "sample");
    assert (n == 3 && s.lists.size == 2 && s.lists[1].name == "Home, Garden");
    var lp = s.find (p.uid);
    assert (lp.list_id == s.lists[1].id && s.find (c.uid).parent_uid == p.uid);
    lp.title = "Changed locally";
    string again_name;
    var again = load_sample (out again_name);
    ICal.import_into (s, again, again_name, "sample");
    assert (s.tasks.size == 3 && s.lists.size == 2);
    assert (s.find (p.uid).title == "Plant the tomatoes, peppers; and basil");
    int done, total;
    s.progress (s.find (p.uid), out done, out total);
    assert (done == 1 && total == 1);
}

void test_export_round_trip () {
    string calname;
    var items = load_sample (out calname);
    var s = new TaskStore ();
    ICal.import_into (s, items, calname, "sample");
    var extra = s.add_task (s.lists[0].id, "Timed reminder, with \"quotes\" and a very long title that surely needs folding at seventy-five octets ✓✓✓");
    extra.due = local (2026, 10, 2, 18, 0);
    extra.due_has_time = true;
    extra.reminder_minutes = 90;
    extra.notes = "multi\nline; notes, with \\ backslash";
    var now = new DateTime.utc (2026, 9, 26, 10, 0, 0);
    string text = ICal.export (s.in_order (s.lists[0].id), s, s.lists[0].name, now);
    foreach (string line in text.split ("\r\n")) {
        assert (line.length <= 75);
    }
    assert (text.has_prefix ("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"));
    assert (text.contains ("RRULE:FREQ=WEEKLY;BYDAY=SA;COUNT=4\r\n"));
    assert (text.contains ("DUE;VALUE=DATE:20260928\r\n"));
    assert (text.contains ("DUE:20260927T130000Z\r\n"));
    assert (text.contains ("TRIGGER;RELATED=END:-PT90M\r\n"));
    assert (text.contains ("LOCATION:Backyard\r\n"));
    assert (text.contains ("CATEGORIES:garden,outdoor,spring\\,summer\r\n"));
    assert (text.contains ("RELATED-TO;RELTYPE=PARENT:todo-parent@example.com\r\n"));
    string back_name;
    var back = ICal.parse (text, out back_name);
    assert (back_name == "Home, Garden");
    assert (back.size == 4);
    var bp = back[0].task;
    var op = s.find (bp.uid);
    assert (bp.title == op.title && bp.notes == op.notes && bp.due.equal (op.due) && bp.due_has_time == op.due_has_time);
    assert (bp.tags.size == 3 && bp.tags[2] == "spring,summer");
    assert (bp.rrule == op.rrule && bp.priority == op.priority);
    assert (bp.reminder_at != null && bp.reminder_at.equal (op.reminder_time ()));
    assert (bp.extra.size == 2 && bp.extra[1] == "LOCATION:Backyard");
    assert (back[0].list_name == "Home, Garden");
    var bc = back[1].task;
    assert (bc.completed && bc.parent_uid == bp.uid && bc.completed_at.equal (s.find (bc.uid).completed_at));
    var bx = back[3].task;
    assert (bx.title == extra.title && bx.notes == extra.notes && bx.due.equal (extra.due) && bx.reminder_minutes == 90);
    var b3 = back[2].task;
    assert (b3.reminder_at.equal (new DateTime.utc (2026, 10, 1, 15, 0, 0)));
}


QuickEntry quick (string text) {
    return QuickParser.parse (text, local (2026, 9, 30, 10, 15));
}

void expect_day (string text, string title, int y, int m, int d) {
    var e = quick (text);
    if (e.title != title || e.due == null || e.due_has_time || !e.due.equal (local (y, m, d))) {
        printerr ("%s: got title '%s' due %s timed %s\n", text, e.title, e.due != null ? e.due.format ("%F %T") : "none", e.due_has_time.to_string ());
        assert_not_reached ();
    }
}

void expect_time (string text, string title, int y, int m, int d, int h, int min) {
    var e = quick (text);
    if (e.title != title || e.due == null || !e.due_has_time || !e.due.equal (local (y, m, d, h, min))) {
        printerr ("%s: got title '%s' due %s timed %s\n", text, e.title, e.due != null ? e.due.format ("%F %T") : "none", e.due_has_time.to_string ());
        assert_not_reached ();
    }
}

void expect_plain (string text) {
    var e = quick (text);
    if (e.title != text || e.due != null || e.rrule != "" || e.understood ()) {
        printerr ("%s: parsed as '%s' due %s rule %s\n", text, e.title, e.due != null ? e.due.format ("%F %T") : "none", e.rrule);
        assert_not_reached ();
    }
}

void test_quick_dates () {
    expect_day ("Buy milk tomorrow", "Buy milk", 2026, 10, 1);
    expect_day ("Call mom today", "Call mom", 2026, 9, 30);
    expect_day ("TODAY call the bank", "call the bank", 2026, 9, 30);
    expect_time ("Take out the trash tonight", "Take out the trash", 2026, 9, 30, 20, 0);
    expect_day ("Dentist next monday", "Dentist", 2026, 10, 5);
    expect_day ("Report on friday", "Report", 2026, 10, 2);
    expect_day ("Gym monday", "Gym", 2026, 10, 5);
    expect_day ("Review wednesday", "Review", 2026, 10, 7);
    expect_day ("Review this wednesday", "Review", 2026, 9, 30);
    expect_day ("Lunch on fri", "Lunch", 2026, 10, 2);
    expect_day ("Pay rent in 3 days", "Pay rent", 2026, 10, 3);
    expect_day ("Renew passport in 2 weeks", "Renew passport", 2026, 10, 14);
    expect_day ("Check in a week", "Check", 2026, 10, 7);
    expect_day ("Car service in 2 months", "Car service", 2026, 11, 30);
    expect_day ("Party on 12 oct", "Party", 2026, 10, 12);
    expect_day ("Party oct 12", "Party", 2026, 10, 12);
    expect_day ("Party on the 12th october", "Party", 2026, 10, 12);
    expect_day ("Trip 3 march", "Trip", 2027, 3, 3);
    expect_day ("Exam 12 october 2027", "Exam", 2027, 10, 12);
    expect_day ("Tax return 2026-10-15", "Tax return", 2026, 10, 15);
    expect_day ("Plan next week", "Plan", 2026, 10, 5);
    expect_day ("Invoices next month", "Invoices", 2026, 10, 1);
    expect_day ("Submit the form by tomorrow", "Submit the form", 2026, 10, 1);
    expect_day ("Pack day after tomorrow", "Pack", 2026, 10, 2);
    var only = quick ("tomorrow");
    assert (only.title == "tomorrow" && only.due.equal (local (2026, 10, 1)));
}

void test_quick_times () {
    expect_time ("Standup 5pm", "Standup", 2026, 9, 30, 17, 0);
    expect_time ("Meet at 17:30", "Meet", 2026, 9, 30, 17, 30);
    expect_time ("Call at 5 pm", "Call", 2026, 9, 30, 17, 0);
    expect_time ("Call at 5:45pm", "Call", 2026, 9, 30, 17, 45);
    expect_time ("Breakfast at 8", "Breakfast", 2026, 10, 1, 8, 0);
    expect_time ("Early 9am", "Early", 2026, 10, 1, 9, 0);
    expect_time ("Lunch at noon", "Lunch", 2026, 9, 30, 12, 0);
    expect_time ("Submit by tomorrow 5pm", "Submit", 2026, 10, 1, 17, 0);
    expect_time ("Dinner friday at 20:00", "Dinner", 2026, 10, 2, 20, 0);
    expect_time ("Flight on 12 oct at 6:30am", "Flight", 2026, 10, 12, 6, 30);
    expect_time ("Midnight snack 12am", "Midnight snack", 2026, 10, 1, 0, 0);
    expect_time ("Cena domani alle 20", "Cena", 2026, 10, 1, 20, 0);
    expect_plain ("Meeting at 25:00");
    expect_plain ("Read chapter 12");
}

void test_quick_repeat_tags () {
    var e = quick ("Water plants every day");
    assert (e.title == "Water plants" && e.rrule == "FREQ=DAILY" && e.due.equal (local (2026, 9, 30)) && !e.due_has_time);
    e = quick ("Standup every weekday at 9");
    assert (e.title == "Standup" && e.rrule == "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR");
    assert (e.due_has_time && e.due.equal (local (2026, 10, 1, 9, 0)));
    e = quick ("Standup every weekday at 11");
    assert (e.due.equal (local (2026, 9, 30, 11, 0)));
    e = quick ("Review every 2 weeks");
    assert (e.title == "Review" && e.rrule == "FREQ=WEEKLY;INTERVAL=2" && e.due.equal (local (2026, 9, 30)));
    e = quick ("Yoga every monday");
    assert (e.title == "Yoga" && e.rrule == "FREQ=WEEKLY;BYDAY=MO" && e.due.equal (local (2026, 10, 5)));
    e = quick ("Backup every other day");
    assert (e.rrule == "FREQ=DAILY;INTERVAL=2");
    e = quick ("Rent every month from 1 oct");
    assert (e.rrule == "FREQ=MONTHLY" && e.title == "Rent from" && e.due.equal (local (2026, 10, 1)));
    e = quick ("Report weekly");
    assert (e.rrule == "FREQ=WEEKLY" && e.title == "Report");
    e = quick ("Birthday every year on 3 march");
    assert (e.rrule == "FREQ=YEARLY" && e.title == "Birthday" && e.due.equal (local (2027, 3, 3)));
    e = quick ("Fix login bug #work #urgent !high");
    assert (e.title == "Fix login bug" && e.priority == Priority.HIGH);
    assert (e.tags.size == 2 && e.tags[0] == "work" && e.tags[1] == "urgent" && e.due == null && e.understood ());
    e = quick ("Tidy desk !low #home, #Home");
    assert (e.priority == Priority.LOW && e.tags.size == 1 && e.tags[0] == "home" && e.title == "Tidy desk");
    e = quick ("Plan trip !medium tomorrow #travel");
    assert (e.priority == Priority.MEDIUM && e.title == "Plan trip" && e.due.equal (local (2026, 10, 1)));
    expect_plain ("Enjoy the sun at the beach");
    expect_plain ("May the force be with you");
    expect_plain ("Pay 31 feb");
    expect_plain ("Every time it rains");
    expect_plain ("Wow!");
    var ignored = new Gee.ArrayList<string> ();
    ignored.add ("Work");
    var now = local (2026, 9, 30, 10, 15);
    var kept = QuickParser.parse_with ("Call Anna tomorrow 5pm #work !high every day", now, false, false, false, ignored);
    assert (kept.title == "Call Anna tomorrow 5pm #work !high every day" && !kept.understood ());
    var partial = QuickParser.parse_with ("Call Anna tomorrow !high #work #home", now, true, true, false, ignored);
    assert (partial.title == "Call Anna !high #work" && partial.priority == Priority.NONE && partial.tags.size == 1 && partial.tags[0] == "home");
    assert (partial.due.equal (local (2026, 10, 1)));
}

void test_quick_italian () {
    expect_day ("Compra pane domani", "Compra pane", 2026, 10, 1);
    expect_day ("Riunione oggi", "Riunione", 2026, 9, 30);
    expect_day ("Palestra lunedì prossimo", "Palestra", 2026, 10, 5);
    expect_day ("Chiamare Luca lunedi", "Chiamare Luca", 2026, 10, 5);
    expect_day ("Consegna tra 3 giorni", "Consegna", 2026, 10, 3);
    expect_day ("Consegna per domani", "Consegna", 2026, 10, 1);
    expect_day ("Festa il 12 ottobre", "Festa", 2026, 10, 12);
    expect_time ("Film stasera", "Film", 2026, 9, 30, 20, 0);
    var e = quick ("Innaffiare ogni giorno");
    assert (e.title == "Innaffiare" && e.rrule == "FREQ=DAILY");
    e = quick ("Scrivere ogni 2 settimane");
    assert (e.rrule == "FREQ=WEEKLY;INTERVAL=2");
}

void test_repeat_rule () {
    var r = RepeatRule.parse ("FREQ=WEEKLY;INTERVAL=2;BYDAY=FR,MO;COUNT=3");
    assert (r != null && r.frequency == RepeatFrequency.WEEKLY && r.interval == 2 && r.count == 3);
    assert (r.days.size == 2 && r.days[0] == 1 && r.days[1] == 5);
    assert (r.to_string () == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,FR;COUNT=3");
    assert (r.next_after (local (2026, 10, 5, 9, 0)).equal (local (2026, 10, 9, 9, 0)));
    assert (r.next_after (local (2026, 10, 9, 9, 0)).equal (local (2026, 10, 19, 9, 0)));
    assert (r.advanced ().count == 2);
    assert (RepeatRule.parse ("RRULE:FREQ=DAILY").next_after (local (2026, 12, 31)).equal (local (2027, 1, 1)));
    assert (RepeatRule.parse ("FREQ=DAILY;INTERVAL=3").next_after (local (2026, 9, 30)).equal (local (2026, 10, 3)));
    assert (RepeatRule.parse ("FREQ=WEEKLY").next_after (local (2026, 9, 30)).equal (local (2026, 10, 7)));
    var weekdays = RepeatRule.parse ("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR");
    assert (weekdays.is_weekdays ());
    assert (weekdays.next_after (local (2026, 10, 2, 9, 0)).equal (local (2026, 10, 5, 9, 0)));
    assert (weekdays.next_after (local (2026, 10, 3)).equal (local (2026, 10, 5)));
    assert (RepeatRule.parse ("FREQ=MONTHLY").next_after (local (2026, 1, 31)).equal (local (2026, 2, 28)));
    assert (RepeatRule.parse ("FREQ=YEARLY").next_after (local (2028, 2, 29)).equal (local (2029, 2, 28)));
    assert (RepeatRule.parse ("FREQ=DAILY;COUNT=1").next_after (local (2026, 9, 30)) == null);
    var until = RepeatRule.parse ("FREQ=DAILY;UNTIL=20261002");
    assert (until.next_after (local (2026, 10, 1, 8, 0)).equal (local (2026, 10, 2, 8, 0)));
    assert (until.next_after (local (2026, 10, 2, 8, 0)) == null);
    var odd = RepeatRule.parse ("FREQ=MONTHLY;BYDAY=-1FR;WKST=SU");
    assert (odd != null && odd.days.size == 0 && odd.to_string () == "FREQ=MONTHLY;BYDAY=-1FR;WKST=SU");
    assert (RepeatRule.parse ("") == null && RepeatRule.parse ("FREQ=SECONDLY") == null && RepeatRule.parse ("garbage") == null);
    assert (RepeatRule.parse ("FREQ=DAILY;INTERVAL=0") == null);
    assert (RepeatRule.describe_text ("FREQ=DAILY") == "Every day");
    assert (RepeatRule.describe_text ("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR") == "Every weekday");
    assert (RepeatRule.describe_text ("FREQ=WEEKLY;INTERVAL=2") == "Every 2 weeks");
    assert (RepeatRule.describe_text ("FREQ=WEEKLY;BYDAY=MO,FR") == "Every week on Monday and Friday");
    assert (RepeatRule.describe_text ("FREQ=MONTHLY;COUNT=3") == "Every month, 3 times left");
    assert (RepeatRule.describe_text ("FREQ=YEARLY;UNTIL=20301231") == "Every year, until 31 Dec 2030");
}

void test_recurring_completion () {
    var s = new TaskStore ();
    var l = s.add_list ("Home");
    var first = s.add_task (l.id, "First");
    var t = s.add_task (l.id, "Water plants");
    var last = s.add_task (l.id, "Last");
    t.due = local (2026, 9, 30, 18, 0);
    t.due_has_time = true;
    t.rrule = "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=2";
    t.tags.add ("garden");
    t.priority = Priority.HIGH;
    t.reminder_minutes = 15;
    t.notes = "Use rain water";
    var sub = s.add_task (l.id, "Balcony", t.uid);
    s.set_completed (sub, true, new DateTime.now_utc ());
    var next = s.set_completed (t, true, new DateTime.now_utc ());
    assert (next != null && t.completed && t.rrule == "");
    assert (next.title == "Water plants" && !next.completed && next.uid != t.uid);
    assert (next.due.equal (local (2026, 10, 5, 18, 0)) && next.due_has_time);
    assert (next.rrule == "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=1");
    assert (next.tags.size == 1 && next.priority == Priority.HIGH && next.reminder_minutes == 15 && next.notes == "Use rain water");
    assert (titles (s.children (l.id, "")) == "First,Water plants,Water plants,Last");
    assert (s.children (l.id, "")[2] == next);
    var subs = s.children (l.id, next.uid);
    assert (subs.size == 1 && subs[0].title == "Balcony" && !subs[0].completed);
    assert (s.set_completed (next, true, new DateTime.now_utc ()) == null && next.rrule == "");
    var plain = s.add_task (l.id, "Once");
    plain.due = local (2026, 9, 30);
    assert (s.set_completed (plain, true, new DateTime.now_utc ()) == null);
    var undated = s.add_task (l.id, "No date");
    undated.rrule = "FREQ=DAILY";
    assert (s.set_completed (undated, true, new DateTime.now_utc ()) == null && undated.rrule == "FREQ=DAILY");
    assert (first.position < t.position && last.position > next.position);
}

void test_recurring_ics () {
    try {
        var s = new TaskStore ();
        var l = s.add_list ("Chores");
        var t = s.add_task (l.id, "Bins");
        t.due = local (2026, 10, 1);
        t.rrule = "FREQ=WEEKLY;INTERVAL=2;BYDAY=TH;UNTIL=20270101T000000Z";
        var now = new DateTime.utc (2026, 9, 30, 8, 0, 0);
        string text = ICal.export (s.in_order (l.id), s, l.name, now);
        assert (text.contains ("RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TH;UNTIL=20270101T000000Z\r\n"));
        string name;
        var back = ICal.parse (text, out name);
        assert (back.size == 1 && back[0].task.rrule == t.rrule);
        var parsed = RepeatRule.parse (back[0].task.rrule);
        assert (parsed.to_string () == t.rrule);
        var json = Storage.serialize (s);
        var s2 = new TaskStore ();
        Storage.deserialize (json, s2);
        assert (s2.tasks[0].rrule == t.rrule);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

void test_focus_timer () {
    try {
        var f = new FocusTimer ();
        f.focus_length = 1500;
        f.break_length = 300;
        string finished_uid = "";
        int64 logged = 0;
        FocusPhase last = FocusPhase.IDLE;
        int events = 0;
        f.phase_finished.connect ((p, uid, secs) => {
            last = p;
            finished_uid = uid;
            logged += secs;
            events++;
        });
        int64 t0 = 1000000;
        f.start ("abc", t0);
        assert (f.phase == FocusPhase.FOCUS && f.remaining (t0) == 1500 && f.task_uid == "abc");
        f.tick (t0 + 600);
        assert (f.remaining (t0 + 600) == 900 && events == 0);
        f.pause (t0 + 600);
        assert (f.remaining (t0 + 2000) == 900);
        f.tick (t0 + 2000);
        assert (f.phase == FocusPhase.FOCUS);
        f.resume (t0 + 2000);
        assert (f.remaining (t0 + 2100) == 800);
        assert (Math.fabs (f.fraction (t0 + 2100) - 700.0 / 1500) < 1e-9);
        f.tick (t0 + 2905);
        assert (events == 1 && last == FocusPhase.FOCUS && finished_uid == "abc" && logged == 1500);
        assert (f.phase == FocusPhase.BREAK && f.remaining (t0 + 2905) == 295);
        f.tick (t0 + 3200);
        assert (events == 2 && last == FocusPhase.BREAK && f.phase == FocusPhase.IDLE && f.task_uid == "");
        assert (logged == 1500);
        f.start ("xyz", t0);
        assert (f.stop (t0 + 125) == 125);
        assert (events == 3 && finished_uid == "xyz" && logged == 1625 && !f.running);
        f.start ("late", t0);
        f.tick (t0 + 1500 + 300 + 50);
        assert (f.phase == FocusPhase.IDLE && events == 5);
        assert (FocusTimer.clock (1500) == "25:00" && FocusTimer.clock (59) == "00:59" && FocusTimer.clock (3725) == "1:02:05");
        assert (FocusTimer.spent (30) == "30 seconds" && FocusTimer.spent (1500) == "25 minutes");
        assert (FocusTimer.spent (3600) == "1 hour" && FocusTimer.spent (4500) == "1 hour 15 minutes");
        var s = new TaskStore ();
        var l = s.add_list ("Work");
        var task = s.add_task (l.id, "Focus");
        task.focus_seconds = 4500;
        var s2 = new TaskStore ();
        Storage.deserialize (Storage.serialize (s), s2);
        assert (s2.tasks[0].focus_seconds == 4500);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

void test_calendar_feed () {
    try {
        var s = new TaskStore ();
        var l = s.add_list ("Work");
        var a = s.add_task (l.id, "Timed");
        a.due = local (2026, 10, 2, 17, 30);
        a.due_has_time = true;
        a.notes = "Bring slides";
        var b = s.add_task (l.id, "All day");
        b.due = local (2026, 10, 1);
        var done = s.add_task (l.id, "Done");
        done.due = local (2026, 10, 1);
        s.set_completed (done, true, new DateTime.now_utc ());
        var trashed = s.add_task (l.id, "Trashed");
        trashed.due = local (2026, 10, 1);
        s.trash (trashed, new DateTime.now_utc ());
        s.add_task (l.id, "Undated");
        var p = new Json.Parser ();
        p.load_from_data (CalendarFeed.build (s));
        var arr = p.get_root ().get_array ();
        assert (arr.get_length () == 2);
        var e0 = arr.get_object_element (0);
        assert (e0.get_string_member ("id") == "task-" + b.uid && e0.get_string_member ("title") == "All day" && e0.get_boolean_member ("all_day"));
        var s0 = new DateTime.from_iso8601 (e0.get_string_member ("start_time"), null);
        var n0 = new DateTime.from_iso8601 (e0.get_string_member ("end_time"), null);
        assert (s0.equal (local (2026, 10, 1)) && n0.equal (local (2026, 10, 2)));
        var e1 = arr.get_object_element (1);
        assert (!e1.get_boolean_member ("all_day") && e1.get_string_member ("description").has_suffix ("Bring slides"));
        var s1 = new DateTime.from_iso8601 (e1.get_string_member ("start_time"), null);
        var n1 = new DateTime.from_iso8601 (e1.get_string_member ("end_time"), null);
        assert (s1.equal (local (2026, 10, 2, 17, 30)) && n1.equal (local (2026, 10, 2, 18, 0)));
        string dir = temp_path ("calendar");
        assert (CalendarFeed.write (s, dir, true));
        assert (!CalendarFeed.write (s, dir, true));
        string file = Path.build_filename (dir, CalendarFeed.FILE_NAME);
        assert (FileUtils.test (file, FileTest.EXISTS));
        var kf = new KeyFile ();
        kf.load_from_file (Path.build_filename (dir, "calendars.ini"), KeyFileFlags.NONE);
        assert (kf.get_string (CalendarFeed.CALENDAR_ID, "name") == "Tasks");
        kf.set_string (CalendarFeed.CALENDAR_ID, "name", "Renamed");
        kf.save_to_file (Path.build_filename (dir, "calendars.ini"));
        b.due = local (2026, 10, 3);
        assert (CalendarFeed.write (s, dir, true));
        kf.load_from_file (Path.build_filename (dir, "calendars.ini"), KeyFileFlags.NONE);
        assert (kf.get_string (CalendarFeed.CALENDAR_ID, "name") == "Renamed");
        CalendarFeed.write (s, dir, false);
        assert (!FileUtils.test (file, FileTest.EXISTS));
        FileUtils.remove (Path.build_filename (dir, "calendars.ini"));
        DirUtils.remove (dir);
    } catch (Error e) {
        error ("%s", e.message);
    }
}

void test_transfer_metadata () {
    try {
        var metadata = new TransferMetadata ();
        var original = new Task ("transferred-task");
        original.list_id = "remote-list";
        original.rrule = "FREQ=WEEKLY;BYDAY=MO";
        original.reminder_minutes = 30;
        original.tags.add ("Work");
        original.priority = Priority.HIGH;
        original.position = 7;
        original.due = local (2026, 10, 1, 17, 30);
        original.due_has_time = true;
        metadata.remember (original);
        metadata.save ();
        var reopened = new TransferMetadata ();
        reopened.load ();
        var task = new Task (original.uid);
        task.list_id = original.list_id;
        task.due = local (2026, 10, 1);
        assert (reopened.restore (task));
        assert (task.rrule == original.rrule && task.reminder_minutes == 30);
        assert (task.tags_text () == "Work" && task.priority == Priority.HIGH && task.position == 7);
        assert (task.due_has_time && task.due.equal (original.due));
        task.due = local (2026, 10, 2);
        task.due_has_time = false;
        assert (reopened.restore (task));
        assert (!task.due_has_time && task.due.equal (local (2026, 10, 2)));
        assert (!reopened.restore (new Task ("another-task")));
    } catch (Error e) {
        error ("%s", e.message);
    }
}

public static int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "C");
    Test.init (ref args);
    Test.add_func ("/tasks/progress", test_progress);
    Test.add_func ("/tasks/ordering", test_ordering);
    Test.add_func ("/tasks/smart-lists", test_smart_lists);
    Test.add_func ("/tasks/search-trash", test_search_and_trash);
    Test.add_func ("/tasks/reminders", test_reminders);
    Test.add_func ("/tasks/json", test_json_round_trip);
    Test.add_func ("/tasks/ical-escaping", test_escaping_and_folding);
    Test.add_func ("/tasks/ical-import", test_import);
    Test.add_func ("/tasks/ical-export", test_export_round_trip);
    Test.add_func ("/tasks/quick-dates", test_quick_dates);
    Test.add_func ("/tasks/quick-times", test_quick_times);
    Test.add_func ("/tasks/quick-repeat-tags", test_quick_repeat_tags);
    Test.add_func ("/tasks/quick-italian", test_quick_italian);
    Test.add_func ("/tasks/repeat-rule", test_repeat_rule);
    Test.add_func ("/tasks/recurring-completion", test_recurring_completion);
    Test.add_func ("/tasks/recurring-ics", test_recurring_ics);
    Test.add_func ("/tasks/focus-timer", test_focus_timer);
    Test.add_func ("/tasks/calendar-feed", test_calendar_feed);
    Test.add_func ("/tasks/transfer-metadata", test_transfer_metadata);
    return Test.run ();
}
}
