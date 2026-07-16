import Toybox.Lang;
import Toybox.Test;

(:test)
function fixture_math_passes(logger as Test.Logger) as Boolean {
    return (2 + 2) == 4;
}

(:test)
function fixture_page_wraps(logger as Test.Logger) as Boolean {
    return fixturePageAfter(2, 1) == 0 && fixturePageAfter(0, -1) == 2;
}
