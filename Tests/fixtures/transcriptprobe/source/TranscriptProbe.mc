// Transcript probe: a minimal valid watch app. The (:test) functions in
// TranscriptProbeTests.mc are the payload; this app only has to build
// with -t and run in the simulator so monkeydo can execute them.
import Toybox.Application;
import Toybox.Graphics;
import Toybox.WatchUi;

class TranscriptProbeApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        return [new TranscriptProbeView()];
    }
}

class TranscriptProbeView extends WatchUi.View {
    function initialize() {
        View.initialize();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
    }
}
