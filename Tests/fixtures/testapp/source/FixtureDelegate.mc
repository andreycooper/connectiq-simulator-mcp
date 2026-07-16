import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

class FixtureDelegate extends WatchUi.BehaviorDelegate {
    private var _view as FixtureView;

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

    function onKey(event as KeyEvent) as Boolean {
        System.println("FIXTURE_KEY " + event.getKey());
        return false;
    }
}
