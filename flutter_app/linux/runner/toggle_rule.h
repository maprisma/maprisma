// The bar icon's toggle (maprisma --toggle), as a decision the tests can run
// (flutter_app/test/runner_toggle_test.dart compiles this header).
#ifndef MAPRISMA_TOGGLE_RULE_H_
#define MAPRISMA_TOGGLE_RULE_H_

#include <glib.h>

typedef enum { MAPRISMA_TOGGLE_HIDE, MAPRISMA_TOGGLE_SHOW, MAPRISMA_TOGGLE_STAY } MaprismaToggle;

// A shown window hides, focused or not (on COSMIC the panel click takes the
// focus first, and a window behind others counts as shown: the family's
// rule). A hidden one is shown, unless it hid by itself less than 600 ms ago
// (a popup that closed on that same click elsewhere); [hidden_at] 0 = not.
static inline MaprismaToggle maprisma_toggle_step(gboolean visible, gint64 hidden_at, gint64 now) {
  if (visible) return MAPRISMA_TOGGLE_HIDE;
  if (hidden_at != 0 && now - hidden_at < 600 * G_TIME_SPAN_MILLISECOND) return MAPRISMA_TOGGLE_STAY;
  return MAPRISMA_TOGGLE_SHOW;
}

#endif  // MAPRISMA_TOGGLE_RULE_H_
