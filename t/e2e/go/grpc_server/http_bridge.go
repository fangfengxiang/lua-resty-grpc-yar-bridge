// Package main implements an HTTP-to-gRPC bridge for the Calculator service.
//
// OpenResty's ngx.location.capture creates HTTP/1.1 subrequests, which are
// incompatible with nginx's grpc_pass (HTTP/2 only). To work around this,
// the Go server also exposes an HTTP endpoint that accepts gRPC frames
// over plain HTTP/1.1 POST requests.
//
// Frame format (same as gRPC over HTTP/2):
//   byte 0:     compression flag (0 = no compression)
//   bytes 1-4:  message length (big-endian uint32)
//   bytes 5+:   protobuf payload
//
// The HTTP bridge decodes the frame, calls the gRPC method in-process,
// and returns the response as a gRPC frame with grpc-status headers.
package main

import (
	"context"
	"encoding/binary"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	calcpb "calc/proto"
)

// methodHandler decodes a protobuf payload, calls the gRPC method, and returns
// the encoded response payload.
type methodHandler func(ctx context.Context, payload []byte) ([]byte, error)

// buildHandlers creates a dispatch table mapping "Service/Method" to handlers.
func buildHandlers(srv *calculatorServer) map[string]methodHandler {
	return map[string]methodHandler{
		"calculator.Calculator/Add": func(ctx context.Context, payload []byte) ([]byte, error) {
			var req calcpb.Calculator_AddRequest
			if err := proto.Unmarshal(payload, &req); err != nil {
				return nil, status.Errorf(codes.InvalidArgument, "unmarshal AddRequest: %v", err)
			}
			resp, err := srv.Add(ctx, &req)
			if err != nil {
				return nil, err
			}
			return proto.Marshal(resp)
		},
		"calculator.Calculator/Subtract": func(ctx context.Context, payload []byte) ([]byte, error) {
			var req calcpb.Calculator_SubtractRequest
			if err := proto.Unmarshal(payload, &req); err != nil {
				return nil, status.Errorf(codes.InvalidArgument, "unmarshal SubtractRequest: %v", err)
			}
			resp, err := srv.Subtract(ctx, &req)
			if err != nil {
				return nil, err
			}
			return proto.Marshal(resp)
		},
	}
}

// startHTTPBridge starts the HTTP-to-gRPC bridge server.
func startHTTPBridge(addr string, srv *calculatorServer) {
	handlers := buildHandlers(srv)

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeGRPCError(w, codes.InvalidArgument, "method not allowed: "+r.Method)
			return
		}

		// Parse path: /{Service}/{Method}
		path := strings.TrimPrefix(r.URL.Path, "/")
		parts := strings.SplitN(path, "/", 2)
		if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
			writeGRPCError(w, codes.InvalidArgument, "invalid path: "+r.URL.Path)
			return
		}
		serviceMethod := parts[0] + "/" + parts[1]

		// Read body (gRPC frame)
		body, err := io.ReadAll(r.Body)
		if err != nil {
			writeGRPCError(w, codes.InvalidArgument, "read body: "+err.Error())
			return
		}

		// Decode gRPC frame
		if len(body) < 5 {
			writeGRPCError(w, codes.InvalidArgument, "short frame: len < 5")
			return
		}
		if body[0] != 0 {
			writeGRPCError(w, codes.Unimplemented, "compression not supported")
			return
		}
		msgLen := binary.BigEndian.Uint32(body[1:5])
		if uint32(len(body)-5) < msgLen {
			writeGRPCError(w, codes.InvalidArgument, "truncated frame")
			return
		}
		payload := body[5 : 5+msgLen]

		// Dispatch to handler
		handler, ok := handlers[serviceMethod]
		if !ok {
			writeGRPCError(w, codes.Unimplemented, "unknown method: "+serviceMethod)
			return
		}

		respPayload, err := handler(r.Context(), payload)
		if err != nil {
			st, _ := status.FromError(err)
			writeGRPCError(w, st.Code(), st.Message())
			return
		}

		// Encode gRPC frame
		frame := make([]byte, 5+len(respPayload))
		frame[0] = 0 // no compression
		binary.BigEndian.PutUint32(frame[1:5], uint32(len(respPayload)))
		copy(frame[5:], respPayload)

		w.Header().Set("Content-Type", "application/grpc")
		w.Header().Set("grpc-status", "0")
		w.WriteHeader(http.StatusOK)
		w.Write(frame)
	})

	log.Printf("HTTP-to-gRPC bridge listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("HTTP bridge failed: %v", err)
	}
}

// writeGRPCError writes a gRPC error response over HTTP.
func writeGRPCError(w http.ResponseWriter, code codes.Code, msg string) {
	w.Header().Set("Content-Type", "application/grpc")
	w.Header().Set("grpc-status", strconv.Itoa(int(code)))
	w.Header().Set("grpc-message", msg)
	w.WriteHeader(http.StatusOK)
}
