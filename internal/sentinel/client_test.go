package sentinel

import "testing"

func TestRedisAddrFromInfo(t *testing.T) {
	tests := []struct {
		name string
		info map[string]string
		want string
	}{
		{
			name: "ip and port",
			info: map[string]string{"ip": "10.0.0.1", "port": "6379"},
			want: "10.0.0.1:6379",
		},
		{
			name: "addr fallback",
			info: map[string]string{"addr": "redis-master:6379"},
			want: "redis-master:6379",
		},
		{
			name: "missing port",
			info: map[string]string{"ip": "10.0.0.1"},
			want: "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := RedisAddrFromInfo(tt.info); got != tt.want {
				t.Fatalf("RedisAddrFromInfo() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestParseKVSlice(t *testing.T) {
	m, err := parseKVSlice([]string{"name", "mymaster", "ip", "127.0.0.1"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if m["name"] != "mymaster" || m["ip"] != "127.0.0.1" {
		t.Fatalf("unexpected map: %#v", m)
	}
}
