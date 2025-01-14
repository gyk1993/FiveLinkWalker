%Yukai controller.

classdef FLW_Controller_ankle_torque <matlab.System & matlab.system.mixin.Propagates & matlab.system.mixin.SampleTime %#codegen
    % PROTECTED PROPERTIES ====================================================
    properties
        cov_q_measured;
        cov_dq_estimated;
        T_sample;
        T;
        RegressFilterHistoryLength;
    end
    properties(Constant)
        total_mass = 32;
    end
    properties(Access = private)
       t0= 0;
       t_prev = 0;
       first_iteration_done = 0;
    end
    properties(Access = private) % change when swing leg change
        GRF_sw_z = 0;
        GRF_st_z = 0;
        rp_swT_ini = zeros(3,1);
        rv_swT_ini = zeros(3,1);
        stToe_pos = zeros(3,1);
        swToe_pos = zeros(3,1);
        l_ini = 0;
    end
    properties(Access = private) % for filters
       l_LeftToe_kf = 0;
       l_RightToe_kf = 0;
       sigma = 0;
       l_stToe_kf = 0;
       command_V = 0;
    end
    properties(Access = private) % for test
       t_test = 0;
    end
    
    % PROTECTED METHODS =====================================================
    methods (Access = protected)
        
        function [u, u_ankle, Data] = stepImpl(obj,EstStates,t_total)
            
            Data = Construct_Data();
            
            q = EstStates.q;
            dq = EstStates.dq;
            s = EstStates.s;
            t = EstStates.t;
            stanceLeg = EstStates.stanceLeg;
            LegSwitch = EstStates.LegSwitch;
           
            
%             obj.command_V = (1-0.002)*obj.command_V + (0.002)*2;
%             V = obj.command_V; % Desired velocity at the end of a step
%             V = 2;
            V = 0;
            if t_total>5
                V = 0.5;
            end
            if t_total>10
                V = 1;
            end
            if t_total>15
                V = 1.5;
            end
            if t_total>20
                V = 2;
            end
            if t_total>25
                V = 2/5*max([0,(30-t_total)]);
            end
            
            if t_total>30
                V = -0.5;
            end
            if t_total>35
                V = -1;
            end
            if t_total>40
                V = -1.5;
            end
            if t_total>45
                V = -2;
            end
%             if t_total>30
% %                 V = 2/2*max([0,(28-t_total)]);
%                 V = 0;
%             end
            obj.command_V = (1-0.002)*obj.command_V + (0.002)*V;
            V = obj.command_V;
            
            Kd = 60;
            Kp = 1000;
            g=9.81; 
            H = 0.6;
            ds = 1/obj.T;
            
            Cov_q_measured = eye(5) * obj.cov_q_measured;
            Cov_dq_estimated = eye(5) * obj.cov_dq_estimated;
            Cov_p_StanceToe = zeros(2,2);
            Cov_v_StanceToe = zeros(2,2);
%             Cov_dq = eye(7) * 0.05;

            
            % construct full q and dq (x,y) with measured q based on stance
            % leg information
            Jp_LT_pre = Jp_LeftToe(q);
            Jp_RT_pre = Jp_RightToe(q);
            rp_Hip2LT = -p_LeftToe(q); % relative position between hip and left toe
            rp_Hip2RT = -p_RightToe(q);
            rv_Hip2LT = -Jp_LT_pre*dq;
            rv_Hip2RT = -Jp_RT_pre*dq;
            if stanceLeg == -1
                Cov_q = [Jp_LT_pre([1,3],[3:7]);eye(5)] * Cov_q_measured * [Jp_LT_pre([1,3],[3:7]);eye(5)]' + [Cov_p_StanceToe,zeros(2,5);zeros(5,7)];
                Cov_dq = [Jp_LT_pre([1,3],[3:7]);eye(5)] * Cov_dq_estimated * [Jp_LT_pre([1,3],[3:7]);eye(5)]' + [Cov_v_StanceToe,zeros(2,5);zeros(5,7)];
            else
                Cov_q = [Jp_RT_pre([1,3],[3:7]);eye(5)] * Cov_q_measured * [Jp_RT_pre([1,3],[3:7]);eye(5)]'; + [Cov_p_StanceToe,zeros(2,5);zeros(5,7)];
                Cov_dq = [Jp_RT_pre([1,3],[3:7]);eye(5)] * Cov_dq_estimated * [Jp_RT_pre([1,3],[3:7]);eye(5)]'+ [Cov_v_StanceToe,zeros(2,5);zeros(5,7)];
            end

            
            p_com = p_COM(q);
            Jp_com = Jp_COM(q);
            dJp_com = dJp_COM(q,dq);
            v_com = Jp_com*dq;
            
            p_LT = p_LeftToe(q);
            Jp_LT = Jp_LeftToe(q);
            dJp_LT = dJp_LeftToe(q,dq);
            v_LT = Jp_LT*dq;
            
            p_RT = p_RightToe(q);
            Jp_RT = Jp_RightToe(q);
            dJp_RT = dJp_RightToe(q,dq);
            v_RT = Jp_RT*dq;
            
            % com position RELATIVE to toes
            
            rp_LT = p_com - p_LT;
            Jrp_LT = Jp_com - Jp_LT;
            dJrp_LT = dJp_com - dJp_LT;
            rv_LT = v_com - v_LT;
            
            rp_RT = p_com - p_RT;
            Jrp_RT = Jp_com - Jp_RT;
            dJrp_RT = dJp_com - dJp_RT;
            rv_RT = v_com - v_RT;
            
            LG = getFLWAngularMomentum(p_com, [q;dq]);
            L_LeftToe = getFLWAngularMomentum(p_LT, [q;dq]);
            L_RightToe = getFLWAngularMomentum(p_RT, [q;dq]);
            L_LeftToe_vg = obj.total_mass*cross(rp_LT, v_com);
            L_RightToe_vg = obj.total_mass*cross(rp_RT, v_com);
            
            L_LeftToe_obs = L_LeftToe;
            L_RightToe_obs = L_RightToe;
            
            % calculating covariance of 
            JL_q_LT = Jq_AMworld_about_pA(q,dq,p_LT,Jp_LT);
            JL_dq_LT = Jdq_AMworld_about_pA(q,dq,p_LT,zeros(3,7));
            Cov_L_LT = JL_q_LT*Cov_q*JL_q_LT' + JL_dq_LT*Cov_dq*JL_dq_LT';
            Cov_L_LTy = Cov_L_LT(2,2);
            
            JL_q_RT = Jq_AMworld_about_pA(q,dq,p_RT,Jp_RT);
            JL_dq_RT = Jdq_AMworld_about_pA(q,dq,p_RT,zeros(3,7));
            Cov_L_RT = JL_q_RT*Cov_q*JL_q_RT' + JL_dq_RT*Cov_dq*JL_dq_RT';
            Cov_L_RTy = Cov_L_RT(2,2);
            
            Cov_rp_LT = Jrp_LT*Cov_q*Jrp_LT';
            Cov_rp_LTx = Cov_rp_LT(1,1);
            
            Cov_rp_RT = Jrp_RT*Cov_q*Jrp_RT';
            Cov_rp_RTx = Cov_rp_RT(1,1);
            
            
            
            if LegSwitch == 1 || obj.first_iteration_done == 0
                if stanceLeg == -1
                    obj.rp_swT_ini = rp_RT;
                    obj.rv_swT_ini = rv_RT;
                    obj.l_stToe_kf = L_LeftToe_obs(2);
%                     obj.sigma = 2.28^2;
                    obj.sigma = Cov_L_LTy;
                    obj.l_ini = L_LeftToe_obs(2);
                else
                    obj.rp_swT_ini = rp_LT;
                    obj.rv_swT_ini = rv_LT;
                    obj.l_stToe_kf = L_RightToe_obs(2);
%                     obj.sigma = 2.28^2;
                    obj.sigma = Cov_L_RTy;
                    obj.l_ini = L_RightToe_obs(2);
                end
                
            end
            
            
            if stanceLeg == -1
                
                p_stT = p_LT;
                Jp_stT = Jp_LT;
                dJp_stT = dJp_LT;
                v_stT = v_LT;
                
                p_swT = p_RT;
                Jp_swT = Jp_RT;
                dJp_swT = dJp_RT;
                v_swT = v_RT;
                
                rp_stT = rp_LT;
                Jrp_stT = Jrp_LT;
                dJrp_stT = dJrp_LT;
                rv_stT = rv_LT;
                
                rp_swT = rp_RT;
                Jrp_swT = Jrp_RT;
                dJrp_swT = dJrp_RT;
                rv_swT = rv_RT;
                
                L_stToe = L_LeftToe;
                L_swToe = L_RightToe;
                
                L_stToe_obs = L_LeftToe_obs;
                L_swToe_obs = L_RightToe_obs;
                
                Cov_L_stTy = Cov_L_LTy;
                Cov_L_swTy = Cov_L_RTy;
                
                Cov_rp_stTx = Cov_rp_LTx;
                Cov_rp_swTx = Cov_rp_RTx;
                
                
            else
                p_stT = p_RT;
                Jp_stT = Jp_RT;
                dJp_stT = dJp_RT;
                v_stT = v_RT;
                
                p_swT = p_LT;
                Jp_swT = Jp_LT;
                dJp_swT = dJp_LT;
                v_swT = v_LT;
                
                rp_stT = rp_RT;
                Jrp_stT = Jrp_RT;
                dJrp_stT = dJrp_RT;
                rv_stT = rv_RT;
                
                rp_swT = rp_LT;
                Jrp_swT = Jrp_LT;
                dJrp_swT = dJrp_LT;
                rv_swT = rv_LT;
                
                L_stToe = L_RightToe;
                L_swToe = L_LeftToe;
                
                L_stToe_obs = L_RightToe_obs;
                L_swToe_obs = L_LeftToe_obs;
                
                Cov_L_stTy = Cov_L_RTy;
                Cov_L_swTy = Cov_L_LTy;
                
                Cov_rp_stTx = Cov_rp_RTx;
                Cov_rp_swTx = Cov_rp_LTx;

            end
            

            % Kalman Filter for angular Momentum
            
            
            At = 1;
            Ct = 1;
            Bt = 1;
%             Rt = Jrp_stT^cov_pos;
%             Qt = 1.5^2;

            
        
            
            ut = obj.T_sample*obj.total_mass*g*rp_stT(1);
            Rt = (obj.T_sample*obj.total_mass*g)^2*Cov_rp_stTx;
            Qt = Cov_L_stTy;
%             if t> obj.RegressFilterHistoryLength*obj.T_sample
%                 Qt = Cov_L_stTy;
%             else
%                 Qt = 100*Cov_L_stTy;
%             end
            
            if obj.t_prev ~= t_total
                l_stToe_bar = obj.l_stToe_kf + ut;
                sigma_bar = At*obj.sigma*At' + Rt;
                Kt = sigma_bar*Ct'*(Ct*sigma_bar*Ct'+Qt)^-1;
                obj.l_stToe_kf = l_stToe_bar + Kt*(L_stToe_obs(2)-Ct*l_stToe_bar);
                obj.sigma = (1-Kt*Ct)*sigma_bar;
            end
            
            
            
            
            T_left = obj.T - t;
%             LBf = 32*(q(2)*dq(1))+LG(2); %%%%%%%% Notice! should use p_com(3) instead of q(2)!!!!!!!!!!!!!!!!!!!!!!
%             LBf = 32*(q(2)*dq(1));
%             pseudo_com_vx = L_stToe(2)/(32*p_com(3)(2));
%             pseudo_com_vx = L_stToe(2)/(32*(p_com(3)-p_stT(3)));
            pseudo_com_vx = L_stToe(2)/(32*H);
%             pseudo_com_vx = v_com(1);
            l = sqrt(g/H);
            one_step_max_vel_gain = obj.T*l*0.2;
%             dx0_next = rp_stT(1)*l*sinh(l*T_left) + rv_stT(1)*cosh(l*T_left);
            dx0_next = rp_stT(1)*l*sinh(l*T_left) + pseudo_com_vx*cosh(l*T_left);
%             dxf_next_goal = median([dx0_next + one_step_max_vel_gain, dx0_next - one_step_max_vel_gain, V]);
            dxf_next_goal = V;
            x0_next = (dxf_next_goal - dx0_next*cosh(l*obj.T))/(l*sinh(l*obj.T));
            % x0_next is the desired relative position of COM to stance foot in the beginning of next step,(at this step it is still swing foot) so that COM velocity can be V at time obj.T
            
            vx0_next = rp_stT(1)*l*sinh(l*T_left) + v_com(1)*cosh(l*T_left);
            
            %% Take Lc into consideration
            Lc_coeff = get_Lc_coeff(obj.l_ini)';
%             Lc_coeff = [671.0493 -184.7523    7.6934]';
%             Lc_coeff = [-1917.92116143600,1567.57997569595,-296.580254117474,10.6511653210999];
            Lc_coeff = [0, Lc_coeff];
            Lc_est = polyval(Lc_coeff,t);
            Lc_effect = Lc_effect_v1(t,obj.T,Lc_coeff,[obj.total_mass,g,rp_swT(3)]);
            
            dx0_next_withLc = rp_stT(1)*l*sinh(l*T_left) + pseudo_com_vx*cosh(l*T_left)+Lc_effect(2);
            
            %% Assume Lc = a*L+b
            a = 2.41;
            b = -81.95;
            k1 = sqrt(g/H);
            k2 = sqrt(a - 1);
            dx0_next_special = rp_stT(1)*k1/k2*sin(k1*k2*T_left) + pseudo_com_vx*cos(k1*k2*T_left) + 1/k2^2*(1-cos(k1*k2*T_left))*(-b/(obj.total_mass*H));
            
            
            
            w = pi/obj.T;
%             H = 0.6 + 0.2*min(1,t_total/10);
            
            CL = 0.1;
            
            ref_rp_swT_x = 1/2*(obj.rp_swT_ini(1) - x0_next)*cos(w*t) + 1/2*(obj.rp_swT_ini(1) + x0_next);
            ref_rv_swT_x = 1/2*(obj.rp_swT_ini(1) - x0_next)*(-w*sin(w*t));
            ref_ra_swT_x = 1/2*(obj.rp_swT_ini(1) - x0_next)*(-w^2*cos(w*t));
            
%             ref_rp_swT_z = 1/2*CL*cos(2*w*t)+(H-1/2*CL);
%             ref_rv_swT_z = 1/2*CL*(-2*w*sin(2*w*t));
%             ref_ra_swT_z = 1/2*CL*(-4*w^2*cos(2*w*t));
            ref_rp_swT_z= 4*CL*(s-0.5)^2+(H-CL);
            ref_rv_swT_z = 8*CL*(s-0.5)*ds;
            ref_ra_swT_z = 8*CL*ds^2;
            
            
            ref_rp_stT_z= H ;
            ref_rv_stT_z = 0;
            ref_ra_stT_z = 0;
%             amp_temp = 0.02;
%             omega_temp = 2*pi;
%             ref_rp_stT_z= H + amp_temp*sin(omega_temp*s-pi/2)+amp_temp;
%             ref_rv_stT_z = omega_temp*ds*amp_temp*cos(omega_temp*s-pi/2);
%             ref_ra_stT_z = -(omega_temp*ds)^2*amp_temp*sin(omega_temp*s-pi/2);
            
            M = InertiaMatrix(q);
            C = CoriolisTerm(q,dq);
            G = GravityVector(q);
            B = [zeros(3,4);eye(4)];
            
            % Jh is jacobian for output
            Jh = zeros(4,7);
            dJh = zeros(4,7);
            
            Jh(1,3) = 1;
            Jh(2,:) = Jrp_stT(3,:);
            Jh([3,4],:) = Jrp_swT([1,3],:);
            
            dJh(2,:) = dJrp_stT(3,:);
            dJh([3,4],:) = dJrp_swT([1,3],:);
            
            %Jg is Jacobian for ground constraint
            Jg = Jp_stT([1,3],:);
            dJg = dJp_stT([1,3],:);
            
            
            % Let the output be torso angle, com height and delta x,delta z of swing
            % feet and com. delta = p_com - p_swfeet.
            h0 = [q(3);rp_stT(3);rp_swT([1,3])];
            dh0 = Jh*dq;
            
            hr= [0;ref_rp_stT_z;ref_rp_swT_x;ref_rp_swT_z];
%             hr= [sqrt(dxf_next_goal)/5;H;ref_rp_swT_x;ref_rp_swT_z];
            dhr = [0;ref_rv_stT_z;ref_rv_swT_x;ref_rv_swT_z];
            ddhr = [0;ref_ra_stT_z;ref_ra_swT_x;ref_ra_swT_z];
            
            Me = [M -Jg';Jg,zeros(2,2)];
            He = [C+G;dJg*dq];
            Be = [B;zeros(2,4)];
            
            S = [eye(7),zeros(7,2)]; % S is used to seperate ddq with Fg;
            
            y = h0 - hr;
            dy = dh0 - dhr;
            
            u = (Jh*S*Me^-1*Be)^-1*(-Kd*dy-Kp*y+ddhr+Jh*S*Me^-1*He);
%             u = 10*ones(4,1)*sin(t);
%             u = zeros(4,1);
%             u_ankle = -100*(s-0.5);
            u_ankle = 30*sin(2*pi*s);
%%          
            Data.t_diff = t_total - obj.t_prev;
            obj.t_prev = t_total;
            obj.t_test = obj.t_test + obj.T_sample;
            
            if obj.first_iteration_done == 0
                obj.first_iteration_done = 1;
            end
%% Data assignment
            Data.Lc_effect = Lc_effect;
            Data.dx0_next_withLc = dx0_next_withLc;
            Data.Lc_est = Lc_est;
            Data.LegSwitch = LegSwitch;

            Data.stanceLeg = stanceLeg;
            Data.lG = LG(2);
            Data.l_LeftToe = L_LeftToe(2);
            Data.l_RightToe = L_RightToe(2);
            Data.l_LeftToe_vg = L_LeftToe_vg(2);
            Data.l_RightToe_vg = L_RightToe_vg(2);
            Data.l_stToe = L_stToe(2);
            
            Data.dx0_next = dx0_next;
            Data.x0_next = x0_next;
            Data.dxf_next_goal = dxf_next_goal;
            
            Data.vx0_next = vx0_next;
            
            Data.hr = hr;
            Data.dhr = dhr;
            Data.h0 = h0;
            Data.dh0 = dh0;
            
            Data.l_stToe_kf = obj.l_stToe_kf;
            Data.l_stToe_obs = L_stToe_obs(2);
            Data.rp_LT = rp_LT;
            Data.sigma = obj.sigma;
            Data.std = sqrt(obj.sigma);
            Data.Rt = Rt;
            Data.Qt = Qt;
            
            Data.t_test = obj.t_test;
            Data.s = s;
            Data.t = t;
            
            Data.p_LT = p_LT;
            Data.p_RT = p_RT;
            Data.v_LT = v_LT;
            Data.v_RT = v_RT;
            
            Data.p_stT = p_stT;
            Data.p_swT = p_swT;
            Data.v_stT = v_stT;
            Data.v_swT = v_swT;
            
            Data.rp_Hip2LT = rp_Hip2LT;
            Data.rp_Hip2RT = rp_Hip2RT;
            Data.rv_Hip2LT = rv_Hip2LT;
            Data.rv_Hip2RT = rv_Hip2RT;
            
            Data.rp_stT = rp_stT;
            Data.rv_stT = rv_stT;
            
            Data.p_com = p_com;
            Data.v_com = v_com;
            Data.vx_com = v_com(1);
            Data.vy_com = v_com(2);
            Data.vz_com = v_com(3);
            Data.px_com = p_com(1);
            Data.py_com = p_com(2);
            Data.pz_com = p_com(3);
            Data.pseudo_com_vx = pseudo_com_vx;
            Data.q = q;
            Data.dq = dq;
            Data.u = u;
            Data.u_ankle = u_ankle;
            
            Data.dx0_next_special = dx0_next_special;
            
            Data.V_command = V;
            
            Data.q1 = q(1);
            Data.q2 = q(2);
            Data.q3 = q(3);
            Data.q4 = q(4);
            Data.q5 = q(5);
            Data.q6 = q(6);
            Data.q7 = q(7);
            
            Data.dq1 = dq(1);
            Data.dq2 = dq(2);
            Data.dq3 = dq(3);
            Data.dq4 = dq(4);
            Data.dq5 = dq(5);
            Data.dq6 = dq(6);
            Data.dq7 = dq(7);
            
        end % stepImpl

        %% Default functions
        function setupImpl(obj)
            %SETUPIMPL Initialize System object.
        end % setupImpl
        
        function resetImpl(~)
            %RESETIMPL Reset System object states.
        end % resetImpl
        
        function [name_1, name_2]  = getInputNamesImpl(~)
            %GETINPUTNAMESIMPL Return input port names for System block
            name_1 = 'EstStates';
            name_2 = 't';
            
        end % getInputNamesImpl      
        
        function [name_1, name_2, name_3] = getOutputNamesImpl(~)
            %GETOUTPUTNAMESIMPL Return output port names for System block
            name_1 = 'u';
            name_2 = 'u_ankle';
            name_3 = 'Data';
            
        end % getOutputNamesImpl
        
        % PROPAGATES CLASS METHODS ============================================
        function [u, u_ankle, Data] = getOutputSizeImpl(~)
            %GETOUTPUTSIZEIMPL Get sizes of output ports.
            u = [4, 1];
            u_ankle = [1, 1];
            Data = [1, 1];
        end % getOutputSizeImpl
        
        function [u, u_ankle, Data] = getOutputDataTypeImpl(~)
            %GETOUTPUTDATATYPEIMPL Get data types of output ports.
            u = 'double';
            u_ankle = 'double';
            Data = 'cassieDataBus';
        end % getOutputDataTypeImpl
        
        function [u, u_ankle, Data] = isOutputComplexImpl(~)
            %ISOUTPUTCOMPLEXIMPL Complexity of output ports.
            u = false;
            u_ankle = false;
            Data = false;
        end % isOutputComplexImpl
        
        function [u, u_ankle, Data] = isOutputFixedSizeImpl(~)
            %ISOUTPUTFIXEDSIZEIMPL Fixed-size or variable-size output ports.
            u = true;
            u_ankle = true;
            Data = true;
        end % isOutputFixedSizeImpl        
    end % methods
end % classdef