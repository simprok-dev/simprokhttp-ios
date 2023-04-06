//
//  File.swift
//  
//
//  Created by Andriy Prokhorenko on 01.04.2023.
//

import Foundation
import simprokmachine
import simproktools
import simprokstate



internal extension Machine {
        
    private static func cancelOutline() -> Outline<HttpOutput, HttpInput, HttpInput, HttpOutput> {
        Outline.create { trigger in
            switch trigger {
            case .ext(.willCancel(let id)):
                return OutlineTransition(
                    Outline.create { trigger in
                        switch trigger {
                        case .int(.didCancel(let id)):
                            return OutlineTransition(
                                .finale(),
                                effects: .ext(.didCancel(id: id))
                            )
                        default:
                            return nil
                        }
                    },
                    effects: .int(.willCancel(id: id))
                )
            default:
                return nil
            }
        }
    }
    
    private static func mainOutline() -> Outline<HttpOutput, HttpInput, HttpInput, HttpOutput> {
        Outline.create { trigger in
            switch trigger {
            case .ext(.willLaunch(let id, let request)):
                return OutlineTransition(
                    Outline.create { trigger in
                        switch trigger {
                        case .int(.didLaunchSucceed(let id)):
                            return OutlineTransition(
                                Outline.create { trigger in
                                    switch trigger {
                                    case .int(.didSucceed(let id, let data, let response)):
                                        return OutlineTransition(
                                            .finale(),
                                            effects: .ext(.didSucceed(id: id, data: data, response: response))
                                        )
                                    case .int(.didFail(let id, let error, let response)):
                                        return OutlineTransition(
                                            .finale(),
                                            effects: .ext(.didFail(id: id, error: error, response: response))
                                        )
                                    default:
                                        return nil
                                    }
                                },
                                effects: .ext(.didLaunchSucceed(id: id))
                            )
                        case .int(.didLaunchFail(let id, let reason)):
                            return OutlineTransition(
                                .finale(),
                                effects: .ext(.didLaunchFail(id: id, reason: reason))
                            )
                        default:
                            return nil
                        }
                    }.switchOnTransition(to: cancelOutline()),
                    effects: .int(.willLaunch(id: id, request: request))
                )
            default:
                return nil
            }
        }
    }
    
    private static func updateState() -> Outline<HttpOutput, HttpInput, HttpInput, HttpOutput> {
        Outline.create { trigger in
            switch trigger {
            case .ext(.willUpdateState(let strategy)):
                return OutlineTransition(
                    Outline.create { trigger in
                        switch trigger {
                        case .int(.didUpdateState(let state)):
                            return OutlineTransition(
                                .finale(),
                                effects: .ext(.didUpdateState(state))
                            )
                        default:
                            return nil
                        }
                    },
                    effects: .int(.willUpdateState(strategy))
                )
            default:
                return nil
            }
        }
    }
    
    static func HttpImplementation(state: HttpState) -> Machine<Input, Output>
    where Input == IdData<String, HttpInput>, Output == IdData<String, HttpOutput> {
        .source(
            typeIntTrigger: HttpOutput.self,
            typeIntEffect: HttpInput.self,
            typeExtTrigger: HttpInput.self,
            typeExtEffect: HttpOutput.self,
            typeRequest: ExecutableRequest.self,
            typeResponse: ExecutableResponse.self,
            typeLaunchReason: Void.self,
            typeCancelReason: ExecutableResponse?.self,
            outlines: [
                { _ in mainOutline() }
            ]
        ) {
            state
        } mapReq: { state, event in
            switch event {
            case .willLaunch(let id, let request):
                let base = request.base ?? state.base
                let path = request.path
                let timeout = request.timeoutInMillis ?? state.timeoutInMillis
                let headers = request.headers ?? state.headers
                let method = request.method
                let body = request.body
                
                guard timeout >= 0 else {
                    return (state, .ext(.didLaunchFail(id: id, reason: .invalidTimeout)))
                }
                
                guard let url = URL(string: base.scheme + "//" + base.host + "/" + base.pathPrefix + path.string) else {
                    return (state, .ext(.didLaunchFail(id: id, reason: .invalidUrl)))
                }
                
                return (
                    state,
                    .int(
                        .willLaunch(
                            id: id,
                            reason: Void(),
                            isLaunchOnMain: false,
                            request: ExecutableRequest(
                                url: url,
                                timeotInterval: Double(timeout) / 1000,
                                headers: headers.reduce([String: String](), { partial, header in
                                    let key = header.name.string
                                    let value = header.value
                                    
                                    var copy = partial
                                    copy[key] = value
                                    
                                    return copy
                                }),
                                body: body,
                                method: method.string
                            )
                        )
                    )
                )
                
            case .willCancel(let id):
                return (state, .int(.willCancel(id: id, reason: nil)))
            case .willUpdateState(let strategy):
                let newState = strategy.function(state)
                return (newState, .ext(.didUpdateState(newState)))
            }
        } mapRes: { state, event in
            switch event {
            case .didLaunch(let id, _):
                return (state, .ext(.didLaunchSucceed(id: id)))
            case .didCancel(let id, let response):
                if let response {
                    switch response {
                    case .success(let data, let value):
                        return (state, .ext(.didSucceed(id: id, data: data, response: value)))
                    case .failure(let error, let value):
                        return (state, .ext(.didFail(id: id, error: error, response: value)))
                    }
                } else {
                    return (state, .ext(.didCancel(id: id)))
                }
            case .didEmit(let id, let response):
                return (state, .int(.willCancel(id: id, reason: response)))
            }
        } holder: {
            RequestHolder()
        } onLaunch: { holder, request, callback in
            holder.task = URLSession.shared.dataTask(with: request.urlRequest) { data, response, error in
                if let error {
                    if let error = error as? URLError {
                        callback(.failure(error: .urlError(error), response: response))
                    } else {
                        callback(.failure(error: .otherError(error), response: response))
                    }
                } else if let data {
                    callback(.success(data: data, response: response))
                } else {
                    callback(.failure(error: .unknown, response: nil))
                }
            }
            
            holder.task?.resume()
        } onCancel: { holder in
            holder.task?.cancel()
            holder.task = nil
        }
    }
}
