package main

// params.go — tolerant readers for the map Nakama hands to MatchInit.
//
// Match parameters reach the handler by two different routes: MatchCreate from
// our own Go code passes native types through in-process, while other paths can
// deliver the same values decoded from JSON, where every number is a float64
// and every slice is []interface{}. A plain type assertion is right for exactly
// one of those and silently yields a zero value for the other, which showed up
// as matches that never started. These accept both shapes.

func paramInt(params map[string]interface{}, key string, def int) int {
	v, ok := params[key]
	if !ok {
		return def
	}
	switch n := v.(type) {
	case int:
		return n
	case int32:
		return int(n)
	case int64:
		return int(n)
	case float32:
		return int(n)
	case float64:
		return int(n)
	}
	return def
}

func paramBool(params map[string]interface{}, key string, def bool) bool {
	if b, ok := params[key].(bool); ok {
		return b
	}
	return def
}

func paramString(params map[string]interface{}, key, def string) string {
	if s, ok := params[key].(string); ok {
		return s
	}
	return def
}

func paramStrings(params map[string]interface{}, key string) []string {
	v, ok := params[key]
	if !ok {
		return nil
	}
	switch list := v.(type) {
	case []string:
		out := make([]string, 0, len(list))
		for _, s := range list {
			if s != "" {
				out = append(out, s)
			}
		}
		return out
	case []interface{}:
		out := make([]string, 0, len(list))
		for _, item := range list {
			if s, ok := item.(string); ok && s != "" {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}
