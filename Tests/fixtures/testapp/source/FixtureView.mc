import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

function fixturePageAfter(page as Number, delta as Number) as Number {
    return (page + delta + 3) % 3;
}

class FixtureView extends WatchUi.View {
    private var _page as Number = 0;
    private var _selected as Boolean = false;
    private var _startedLogged as Boolean = false;

    function initialize() {
        View.initialize();
    }

    function move(delta as Number) as Void {
        _page = fixturePageAfter(_page, delta);
        System.println("FIXTURE_PAGE " + _page);
        WatchUi.requestUpdate();
    }

    function toggleSelected() as Void {
        _selected = !_selected;
        System.println("FIXTURE_SELECTED " + _selected);
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var patchColor = Graphics.COLOR_RED;
        if (_page == 1) {
            patchColor = Graphics.COLOR_GREEN;
        } else if (_page == 2) {
            patchColor = Graphics.COLOR_BLUE;
        }

        dc.setColor(patchColor, patchColor);
        dc.fillRectangle(48, 48, 64, 64);

        if (_selected) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_WHITE);
            dc.fillRectangle((dc.getWidth() - 32) / 2, (dc.getHeight() - 32) / 2, 32, 32);
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            dc.getWidth() / 2,
            dc.getHeight() - 32,
            Graphics.FONT_MEDIUM,
            "PAGE " + _page,
            Graphics.TEXT_JUSTIFY_CENTER
        );

        if (!_startedLogged) {
            _startedLogged = true;
            System.println("FIXTURE_STARTED");
        }
    }
}
