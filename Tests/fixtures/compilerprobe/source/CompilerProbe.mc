// Compiler probe: the two diagnostics below sit on FIXED line numbers that
// the captured SDK transcripts (and the diagnostics parser tests) assert
// on. Do not insert or remove lines above them.
import Toybox.Application;
import Toybox.WatchUi;

class CompilerProbeApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        var unusedLocal = 42; // line 13: -w must flag this unused local
    }

    function getInitialView() {
        thisSymbolDoesNotExist(); // line 17: unknown symbol, must be an error
        return [new CompilerProbeView()];
    }
}

class CompilerProbeView extends WatchUi.View {
    function initialize() {
        View.initialize();
    }
}
