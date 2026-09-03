package main

import (
	"fmt"
	"os"
	"strings"
	"unicode"
)

func peekConfigPath(args []string) (string, error) {
	for i, a := range args {
		switch {
		case a == "--config" || a == "-config":
			if i+1 >= len(args) {
				return "", fmt.Errorf("--config requires a file path")
			}
			return args[i+1], nil
		case strings.HasPrefix(a, "--config="):
			p := strings.TrimPrefix(a, "--config=")
			if p == "" {
				return "", fmt.Errorf("--config requires a file path")
			}
			return p, nil
		case strings.HasPrefix(a, "-config="):
			p := strings.TrimPrefix(a, "-config=")
			if p == "" {
				return "", fmt.Errorf("--config requires a file path")
			}
			return p, nil
		}
	}
	return "", nil
}

func layerGetenv(primary getenvFunc, file map[string]string) getenvFunc {
	if primary == nil {
		primary = func(string) string { return "" }
	}
	return func(k string) string {
		if v := strings.TrimSpace(primary(k)); v != "" {
			return v
		}
		if file == nil {
			return ""
		}
		return file[k]
	}
}

func loadEnvFile(path string) (map[string]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read --config %s: %w", path, err)
	}
	out := make(map[string]string)
	for i, raw := range strings.Split(string(b), "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(raw, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "export ") {
			line = strings.TrimSpace(strings.TrimPrefix(line, "export"))
		}
		key, val, err := parseEnvLine(line)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", path, i+1, err)
		}
		out[key] = val
	}
	return out, nil
}

func parseEnvLine(line string) (key, val string, err error) {
	eq := strings.IndexByte(line, '=')
	if eq <= 0 {
		return "", "", fmt.Errorf("expected KEY=VALUE")
	}
	key = strings.TrimSpace(line[:eq])
	if !validEnvKey(key) {
		return "", "", fmt.Errorf("invalid key %q", key)
	}
	rest := line[eq+1:]
	if rest == "" {
		return key, "", nil
	}
	switch rest[0] {
	case '"':
		v, err := unquoteDouble(rest)
		return key, v, err
	case '\'':
		v, err := unquoteSingle(rest)
		return key, v, err
	default:
		return key, strings.TrimSpace(rest), nil
	}
}

func validEnvKey(k string) bool {
	if k == "" {
		return false
	}
	for i, r := range k {
		if i == 0 {
			if r != '_' && !unicode.IsLetter(r) {
				return false
			}
			continue
		}
		if r != '_' && !unicode.IsLetter(r) && !unicode.IsDigit(r) {
			return false
		}
	}
	return true
}

func unquoteDouble(s string) (string, error) {
	var b strings.Builder
	escaped := false
	closed := false
	for i := 1; i < len(s); i++ {
		c := s[i]
		if escaped {
			b.WriteByte(c)
			escaped = false
			continue
		}
		if c == '\\' {
			escaped = true
			continue
		}
		if c == '"' {
			closed = true
			tail := strings.TrimSpace(s[i+1:])
			if tail != "" && !strings.HasPrefix(tail, "#") {
				return "", fmt.Errorf("trailing garbage after quoted value")
			}
			break
		}
		b.WriteByte(c)
	}
	if !closed {
		return "", fmt.Errorf("unterminated double quote")
	}
	return b.String(), nil
}

func unquoteSingle(s string) (string, error) {
	end := strings.IndexByte(s[1:], '\'')
	if end < 0 {
		return "", fmt.Errorf("unterminated single quote")
	}
	end++
	tail := strings.TrimSpace(s[end+1:])
	if tail != "" && !strings.HasPrefix(tail, "#") {
		return "", fmt.Errorf("trailing garbage after quoted value")
	}
	return s[1:end], nil
}
