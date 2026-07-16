import Toybox.Application;
import Toybox.Lang;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

class FixtureApp extends Application.AppBase {
    hidden var _positionTimer as Timer.Timer or Null = null;
    hidden var _lastGpsMarker as String or Null = null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        _lastGpsMarker = null;
        _positionTimer = new Timer.Timer();
        (_positionTimer as Timer.Timer).start(method(:pollPosition), 250, true);
    }

    function onStop(state as Dictionary?) as Void {
        if (_positionTimer != null) {
            (_positionTimer as Timer.Timer).stop();
            _positionTimer = null;
        }
        Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
    }

    function getInitialView() {
        var view = new FixtureView();
        return [view, new FixtureDelegate(view)];
    }

    function pollPosition() as Void {
        var info = Position.getInfo();
        emitPosition(info.position);
    }

    function onPosition(info as Position.Info) as Void {
        emitPosition(info.position);
        WatchUi.requestUpdate();
    }

    hidden function emitPosition(position) as Void {
        if (position == null) {
            return;
        }
        var degrees = position.toDegrees();
        var marker = "FIXTURE_GPS " + degrees[0].format("%.4f") + " "
            + degrees[1].format("%.4f");
        if (_lastGpsMarker == marker) {
            return;
        }
        _lastGpsMarker = marker;
        System.println(marker);
    }
}
