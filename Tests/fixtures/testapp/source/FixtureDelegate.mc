import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class FixtureDelegate extends WatchUi.BehaviorDelegate {
    private var _view as FixtureView;
    private var _downMs as Lang.Dictionary = {};

    function initialize(view as FixtureView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onNextPage() as Boolean {
        _view.move(1);
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.move(-1);
        return true;
    }

    function onSelect() as Boolean {
        _view.toggleSelected();
        return true;
    }

    function onBack() as Boolean {
        System.println("FIXTURE_BACK");
        return true;
    }

    function onKeyPressed(keyEvent as WatchUi.KeyEvent) as Lang.Boolean {
        var id = keyName(keyEvent.getKey());
        if (id == null) { return false; }
        _downMs[id] = System.getTimer();
        return true;
    }

    function onKeyReleased(keyEvent as WatchUi.KeyEvent) as Lang.Boolean {
        var id = keyName(keyEvent.getKey());
        if (id == null) { return false; }
        var started = _downMs[id];
        _downMs.remove(id);
        if (started == null) { return true; }
        var kind = (System.getTimer() - started >= 300) ? "HOLD" : "PRESS";
        System.println("FIXTURE_KEY " + id + " " + kind);
        return true;
    }

    private function keyName(key as WatchUi.Key) as Lang.String? {
        if (key == WatchUi.KEY_ENTER) { return "enter"; }
        if (key == WatchUi.KEY_UP) { return "up"; }
        if (key == WatchUi.KEY_MENU) { return "menu"; }
        if (key == WatchUi.KEY_DOWN) { return "down"; }
        if (key == WatchUi.KEY_ESC) { return "esc"; }
        return null;
    }
}
