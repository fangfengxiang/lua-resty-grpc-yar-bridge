// Package calc implements a Go gRPC server for the Calculator service.
//
// 用途（场景1后端）：PHP Yar client → OpenResty (yar2grpc) → Go gRPC server
// 用途（场景2验证）：也可作为场景2的后端，但场景2后端通常用 PHP Yar server。
//
// 编译：cd t/e2e/go && go build -o bin/grpc_server ./grpc_server
// 运行：./bin/grpc_server -addr 127.0.0.1:50051
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/reflection"
	"google.golang.org/grpc/status"

	calcpb "calc/proto"
)

type calculatorServer struct {
	calcpb.UnimplementedCalculatorServer
}

func (s *calculatorServer) Add(ctx context.Context, req *calcpb.Calculator_AddRequest) (*calcpb.Calculator_AddResponse, error) {
	result := req.GetA() + req.GetB()
	log.Printf("gRPC Add(%d, %d) = %d", req.GetA(), req.GetB(), result)
	return &calcpb.Calculator_AddResponse{Result: result}, nil
}

func (s *calculatorServer) Subtract(ctx context.Context, req *calcpb.Calculator_SubtractRequest) (*calcpb.Calculator_SubtractResponse, error) {
	if req.GetA() < req.GetB() {
		return nil, status.Errorf(codes.InvalidArgument, "a(%d) < b(%d), result would be negative", req.GetA(), req.GetB())
	}
	result := req.GetA() - req.GetB()
	log.Printf("gRPC Subtract(%d, %d) = %d", req.GetA(), req.GetB(), result)
	return &calcpb.Calculator_SubtractResponse{Result: result}, nil
}

func main() {
	addr     := flag.String("addr", "127.0.0.1:50051", "gRPC listen address")
	httpAddr := flag.String("http-addr", "127.0.0.1:50052", "HTTP-to-gRPC bridge listen address")
	flag.Parse()

	// Start HTTP-to-gRPC bridge in background (for OpenResty reverse bridge)
	calcSrv := &calculatorServer{}
	go startHTTPBridge(*httpAddr, calcSrv)

	lis, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", *addr, err)
	}

	srv := grpc.NewServer()
	calcpb.RegisterCalculatorServer(srv, calcSrv)

	// Enable gRPC reflection for debugging
	reflection.Register(srv)

	fmt.Printf("Calculator gRPC server listening on %s (HTTP bridge on %s)\n", *addr, *httpAddr)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("failed to serve: %v", err)
	}
}
