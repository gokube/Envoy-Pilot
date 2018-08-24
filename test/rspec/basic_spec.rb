require 'rest-client'
require 'json'
require 'plissken'
require 'diplomat'

Diplomat.configure do |config|
    config.url = 'http://localhost:8500'
end

listener0_json = %Q{
    {
        "name": "listener_0",
        "address": {
            "socket_address": {
                "address": "0.0.0.0",
                "port_value": 80
            }
        },
        "filter_chains": [
            {
                "filters": [
                    {
                        "name": "envoy.http_connection_manager",
                        "config": {
                            "stat_prefix": "ingress_http",
                            "access_log": [],
                            "codec_type": "HTTP2",
                            "route_config": {
                                "name": "local_http_router",
                                "virtual_hosts": [
                                    {
                                        "name": "local_service",
                                        "domains": [
                                            "*"
                                        ],
                                        "routes": [
                                            {
                                                "match": {
                                                    "prefix": "/"
                                                },
                                                "route": {
                                                    "cluster": "app1"
                                                }
                                            }
                                        ]
                                    }
                                ]
                            },
                            "http_filters": [
                                {
                                    "name": "envoy.health_check",
                                    "config": {
                                        "pass_through_mode": false,
                                        "endpoint": "/healthz"
                                    }
                                },
                                {
                                    "name": "envoy.router"
                                }
                            ]
                        }
                    }
                ]
            }
        ]
    }
}

listener1_json = %Q{
    {
        "name": "listener_1",
        "address": {
           "socket_address": {
              "address": "127.0.0.1",
              "port_value": 10001
           }
        },
        "filter_chains": [
           {
              "filters": [
                 {
                    "name": "envoy.http_connection_manager",
                    "config": {
                       "stat_prefix": "ingress_http",
                       "access_log": [
                          {
                             "name": "envoy.file_access_log",
                             "config": {
                                "path": "/dev/stdout",
                                "format": "some-format"
                             }
                          }
                       ],
                       "codec_type": "HTTP2",
                       "rds": {
                          "route_config_name": "listener_1_route",
                          "config_source": {
                             "api_config_source": {
                                "api_type": "GRPC",
                                "grpc_services": [{
                                   "envoy_grpc": {
                                      "cluster_name": "xds_cluster"
                                   }
                                }]
                             }
                          }
                       },
                       "http_filters": [
                          {
                             "name": "envoy.router"
                          }
                       ]
                    }
                 }
              ]
           }
        ]
     }
}

listeners_json = %Q{
    [
    #{listener0_json},
    #{listener1_json}
    ]
}

cluster0_json = %Q{
    {
        "name": "app1",
        "connect_timeout": "0.250s",
        "type": "strict_dns",
        "lb_policy": "RANDOM",
        "http2_protocol_options": {},
        "hosts": [{
          "socket_address": {
           "address": "127.0.0.2",
           "port_value": 1234
          }
        }]
    }
}

cluster1_json = %Q{
    {
        "name": "app1-grpc",
        "connect_timeout": "0.250s",
        "type": "strict_dns",
        "lb_policy": "RANDOM",
        "http2_protocol_options": {
            "hpack_table_size": 12,
            "max_concurrent_streams": 14,
            "initial_stream_window_size": 268435456,
            "initial_connection_window_size": 268435456
        },
        "hosts": [{
          "socket_address": {
           "address": "127.0.0.2",
           "port_value": 1234
          }
        }]
    }
}

clusters_json = %Q{
    [
        #{cluster0_json},
        #{cluster1_json}
    ]
}

route0_json = %Q{
    {
        "name": "listener_1_route",
        "virtual_hosts": [
            {
                "name": "local_service",
                "domains": [
                    "*"
                ],
                "routes": [
                    {
                        "match": {
                            "prefix": "/"
                        },
                        "route": {
                            "cluster": "app1"
                        }
                    }
                ]
            }
        ]
    }
}

routes_json = %Q{
    [
        #{route0_json}
    ]
}

cluster_version = "1.0"
listener_version = "1.0"
route_version = "1.0"

def getDynamicCluster port, idx
    resp = RestClient.get "http://localhost:#{port}/config_dump"
    json = JSON.parse(resp)
    actual = json["configs"]["clusters"]["dynamicActiveClusters"][idx]["cluster"]
    actual = actual.to_snake_keys
    return actual
end

def getDynamicListener port, idx
    resp = RestClient.get "http://localhost:#{port}/config_dump"
    json = JSON.parse(resp)
    actual = json["configs"]["listeners"]["dynamicActiveListeners"][idx]["listener"]
    actual = actual.to_snake_keys
    return actual
end

def getDynamicRoute port, idx
    resp = RestClient.get "http://localhost:#{port}/config_dump"
    json = JSON.parse(resp)
    actual = json["configs"]["routes"]["dynamicRouteConfigs"][idx]["routeConfig"]
    actual = actual.to_snake_keys
    return actual
end

def getVersion port, key1, key2, idx
    resp = RestClient.get "http://localhost:#{port}/config_dump"
    json = JSON.parse(resp)
    actualVersion = json["configs"][key1][key2][idx]["versionInfo"] 
end

describe "xDS" do
    let(:port) { 9901 }
    before(:all) do
        CLUSTER_KEY = "cluster/cdstest-cluster/node/cdstest-node/cluster"
        LISTENER_KEY = "cluster/cdstest-cluster/node/cdstest-node/listener"
        ROUTE_KEY = "cluster/cdstest-cluster/node/cdstest-node/route"

        cdelete(CLUSTER_KEY)
        cdelete(LISTENER_KEY)
        cdelete(ROUTE_KEY)

        cset("#{CLUSTER_KEY}/config", clusters_json)
        cset("#{CLUSTER_KEY}/version", cluster_version)

        cset("#{LISTENER_KEY}/config", listeners_json)
        cset("#{LISTENER_KEY}/version", listener_version)

        cset("#{ROUTE_KEY}/config", routes_json)
        cset("#{ROUTE_KEY}/version", route_version)

        # port = 9901
        # sleep 60
    end

    describe "CDS" do
        it "Add a cluster" do
            actual = getDynamicCluster(port, 0)
            actualVersion = getVersion(port, "clusters", "dynamicActiveClusters", 0)
            
            expected = JSON.parse(clusters_json)
            expected[0]["type"] = expected[0]["type"].upcase

            expect(actual).to eq(expected[0])
            expect(actualVersion).to eq(cluster_version)
        end

        it "Add a cluster with http2 options" do
            actual = getDynamicCluster(port, 1)
            actualVersion = getVersion(port, "clusters", "dynamicActiveClusters", 1)
            
            expected = JSON.parse(clusters_json)
            expected[1]["type"] = expected[1]["type"].upcase

            expect(actual).to eq(expected[1])
            expect(actualVersion).to eq(cluster_version)
        end
    end

    describe "LDS" do
        it 'Add a listener without rds' do
            actual = getDynamicListener(port, 0)
            actualVersion = getVersion(port, "listeners", "dynamicActiveListeners", 0)

            expected = JSON.parse(listeners_json)
            
            expect(actual).to eq(expected[0])
            expect(actualVersion).to eq(listener_version)
        end

        it 'Add a listener with rds' do
            actual = getDynamicListener(port, 1)
            actualVersion = getVersion(port, "listeners", "dynamicActiveListeners", 1)

            expected = JSON.parse(listeners_json)
            
            expect(actual).to eq(expected[1])
            expect(actualVersion).to eq(listener_version)
        end
    end

    describe "RDS" do
        it 'Add a dynamic route' do
            actual = getDynamicRoute(port, 0)
            actualVersion = getVersion(port, "routes", "dynamicRouteConfigs", 0)

            expected = JSON.parse(routes_json)
            
            expect(actual).to eq(expected[0])
            expect(actualVersion).to eq(route_version)
        end
    end

    describe "Aggregated Discovery Services(ADS)" do
        let(:port) { 9902 }

        describe "CDS" do
            it "Add a cluster" do
                actual = getDynamicCluster(port, 0)
                actualVersion = getVersion(port, "clusters", "dynamicActiveClusters", 0)
                
                expected = JSON.parse(clusters_json)
                expected[0]["type"] = expected[0]["type"].upcase
    
                expect(actual).to eq(expected[0])
                expect(actualVersion).to eq(cluster_version)
            end
    
            it "Add a cluster with http2 options" do
                actual = getDynamicCluster(port, 1)
                actualVersion = getVersion(port, "clusters", "dynamicActiveClusters", 1)
                
                expected = JSON.parse(clusters_json)
                expected[1]["type"] = expected[1]["type"].upcase
    
                expect(actual).to eq(expected[1])
                expect(actualVersion).to eq(cluster_version)
            end
        end
    
        describe "LDS" do
            it 'Add a listener without rds' do
                actual = getDynamicListener(port, 0)
                actualVersion = getVersion(port, "listeners", "dynamicActiveListeners", 0)
    
                expected = JSON.parse(listeners_json)
                
                expect(actual).to eq(expected[0])
                expect(actualVersion).to eq(listener_version)
            end
    
            it 'Add a listener with rds' do
                actual = getDynamicListener(port, 1)
                actualVersion = getVersion(port, "listeners", "dynamicActiveListeners", 1)
    
                expected = JSON.parse(listeners_json)
                
                expect(actual).to eq(expected[1])
                expect(actualVersion).to eq(listener_version)
            end
        end
    
        describe "RDS" do
            it 'Add a dynamic route' do
                actual = getDynamicRoute(port, 0)
    
                expected = JSON.parse(routes_json)
                
                expect(actual).to eq(expected[0])
            end
        end
    end
  end

  def cset key, val
    Diplomat::Kv.put(key, val)
  end

  def cdelete key
    Diplomat::Kv.delete(key)
  end