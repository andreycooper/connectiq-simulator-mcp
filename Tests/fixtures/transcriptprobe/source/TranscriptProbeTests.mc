// The three probe tests the captured transcripts are built from. Their
// names and behaviors are pinned by the plan (Task 6): probe_pass returns
// true, probe_fail returns false through the test API, and probe_error
// performs a deterministic out-of-bounds access.
import Toybox.Lang;
import Toybox.Test;

(:test)
function probe_pass(logger as Test.Logger) as Boolean {
    logger.debug("probe_pass ran");
    return true;
}

(:test)
function probe_fail(logger as Test.Logger) as Boolean {
    logger.debug("probe_fail ran");
    return false;
}

(:test)
function probe_error(logger as Test.Logger) as Boolean {
    var items = [1] as Array<Number>;
    // items.size() + 1 is always out of bounds; computing the index at
    // runtime keeps this a runtime ERROR, never a compile-time finding.
    var outOfBounds = items.size() + 1;
    return items[outOfBounds] == 1;
}
