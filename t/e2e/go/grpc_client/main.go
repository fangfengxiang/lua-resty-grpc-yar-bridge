// Package calc implements a Go gRPC client for the Calculator service.
//
// 用途（场景2客户端）：Go gRPC client → OpenResty (bridge) → PHP Yar server
//
// 编译：cd t/e2e/go && go build -o bin/grpc_client ./grpc_client
// 运行：./bin/grpc_client -addr 127.0.0.1:1984
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"

	calcpb "calc/proto"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:1984", "OpenResty gRPC proxy address")
	useTLS := flag.Bool("tls", false, "use TLS (https) connection")
	flag.Parse()

	var creds credentials.TransportCredentials
	if *useTLS {
		creds = credentials.NewTLS(&tls.Config{InsecureSkipVerify: true})
	} else {
		creds = insecure.NewCredentials()
	}

	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(creds))
	if err != nil {
		log.Fatalf("failed to connect to %s: %v", *addr, err)
	}
	defer conn.Close()

	client := calcpb.NewCalculatorClient(conn)

	// 测试 Add
	{
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		resp, err := client.Add(ctx, &calcpb.Calculator_AddRequest{A: 15, B: 27})
		if err != nil {
			log.Fatalf("Add(15, 27) failed: %v", err)
		}
		fmt.Printf("gRPC Add(15, 27) = %d\n", resp.GetResult())
		if resp.GetResult() != 42 {
			log.Fatalf("Expected 42, got %d", resp.GetResult())
		}
		fmt.Println("Add: PASS")
	}

	// 测试 Subtract
	{
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		resp, err := client.Subtract(ctx, &calcpb.Calculator_SubtractRequest{A: 100, B: 37})
		if err != nil {
			log.Fatalf("Subtract(100, 37) failed: %v", err)
		}
		fmt.Printf("gRPC Subtract(100, 37) = %d\n", resp.GetResult())
		if resp.GetResult() != 63 {
			log.Fatalf("Expected 63, got %d", resp.GetResult())
		}
		fmt.Println("Subtract: PASS")
	}

	fmt.Println("Scenario 2 (Go gRPC → OpenResty → PHP Yar): PASS")
}
